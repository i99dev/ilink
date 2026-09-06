// dash NDK secrets module — native-side integrity probes.
//
// Architecture:
//   - All exposed functions are file-private (`static`) and registered
//     via RegisterNatives in JNI_OnLoad. Result: `nm` / `objdump -T` /
//     `strings` against libdash_secrets.so reveals exactly one exported
//     symbol — JNI_OnLoad. The actual probe names never appear, so the
//     attacker can't grep their way to the entry points.
//
//   - JNI_OnLoad is also the place where we snapshot ptrace state once
//     and cache it for later queries. If a debugger is attached BEFORE
//     library load (the common case for runtime instrumentation), the
//     PTRACE_TRACEME call fails with EPERM and we record `traced=true`
//     for the lifetime of the process. An attacker who attaches later
//     can't undo the snapshot without re-loading the lib.
//
//   - String obfuscation: the names of what we look for (Frida agent,
//     /proc paths, ptrace), AND the JNI plumbing strings (class FQCN,
//     native method names) are XOR-encoded at compile time via the
//     helpers in obfuscation.h. The `.rodata` of the produced .so does
//     not contain plaintext copies of these — they materialise on the
//     stack at use and live for the duration of one function call.
//
// Probes implemented here:
//   1. ptrace_traced       — fail-fast EPERM check; far harder to
//                            bypass than reading TracerPid
//   2. tracer_pid          — kept for the multi-probe cross-check
//   3. has_frida_in_maps   — /proc/self/maps scan with rotated needles
//   4. ping / abi          — smoke tests; not secrets
//
// Hardening notes:
//   - `-fvisibility=hidden` in CMakeLists.txt makes everything except
//     JNIEXPORT-marked symbols local. Only JNI_OnLoad uses JNIEXPORT.
//   - `-Wl,-x` strips local symbols at link time.

#include <jni.h>
#include <android/log.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <string>

#include "obfuscation.h"

#define LOG_TAG "ds"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

using dash::obf::ObfBytes;
using dash::obf::deobfuscate;

// ─── Obfuscated literals ────────────────────────────────────────────
// All declared at namespace scope so they live in .rodata as XOR'd
// bytes, not as plaintext.

OBF_STR(kProcStatusPath, "/proc/self/status");
OBF_STR(kProcMapsPath,   "/proc/self/maps");
OBF_STR(kTracerPidKey,   "TracerPid:");

// Frida fingerprints — substring needles scanned in /proc/self/maps.
// Renaming `frida-agent.so` doesn't make all of these go away — gum-js-loop
// is a thread-name signature, pool-frida is the worker-pool name, etc.
OBF_STR(kNeedle0, "frida-agent");
OBF_STR(kNeedle1, "frida-gum");
OBF_STR(kNeedle2, "gum-js-loop");
OBF_STR(kNeedle3, "linjector");
OBF_STR(kNeedle4, "pool-frida");
OBF_STR(kNeedle5, "frida-server");

// JNI plumbing. The Java class FQCN and the native method names are
// passed to env->FindClass / env->RegisterNatives at load time only;
// they don't need to be in .rodata as plaintext. Decoded once into a
// stack buffer in JNI_OnLoad and discarded immediately.
OBF_STR(kClass,           "com/i99dev/ilink/security/NativeSecrets");
OBF_STR(kMethodPing,      "nativePing");
OBF_STR(kMethodTracerPid, "nativeTracerPid");
OBF_STR(kMethodHasFrida,  "nativeHasFridaInMaps");
OBF_STR(kMethodTraced,    "nativeTracedAtLoad");
OBF_STR(kMethodAbi,       "nativeAbi");

// JNI signatures stay plaintext — they're standard Java type strings
// ("()Z", "()I", "()Ljava/lang/String;") and obfuscating them gives
// zero added difficulty to an attacker who knows JNI. They also appear
// in many other libraries on the device, so they're noise.
constexpr const char* kSigString = "()Ljava/lang/String;";
constexpr const char* kSigInt    = "()I";
constexpr const char* kSigBool   = "()Z";

// Snapshot — ptrace already engaged when our library loaded?
std::atomic<bool> g_traced_at_load{false};

// ─── Helpers ────────────────────────────────────────────────────────

// Read a /proc file into a bounded buffer. Empty on any I/O error so
// callers fail closed (= "no signal", not "tampered").
std::string read_proc_file(const char* path, size_t cap = 8192) {
    int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return {};
    std::string out;
    out.reserve(cap);
    char buf[512];
    while (true) {
        ssize_t n = ::read(fd, buf, sizeof(buf));
        if (n <= 0) break;
        out.append(buf, static_cast<size_t>(n));
        if (out.size() >= cap) break;
    }
    ::close(fd);
    return out;
}

// Parse "TracerPid:\tN" from /proc/self/status. -1 on parse failure.
// `key_text` is the deobfuscated "TracerPid:" string the caller passes
// in — kept on the stack so the plaintext lives only for one call.
int parse_tracer_pid(const std::string& status, const char* key_text) {
    auto pos = status.find(key_text);
    if (pos == std::string::npos) return -1;
    pos += std::strlen(key_text);
    while (pos < status.size() &&
           (status[pos] == ' ' || status[pos] == '\t')) {
        ++pos;
    }
    int v = 0;
    while (pos < status.size() && status[pos] >= '0' && status[pos] <= '9') {
        v = v * 10 + (status[pos] - '0');
        ++pos;
    }
    return v;
}

// PTRACE_TRACEME fails with EPERM if we're already being traced. One-
// shot at lib load — the kernel detaches implicitly on thread exit.
void snapshot_ptrace_state() {
    long rc = ::ptrace(PTRACE_TRACEME, 0, nullptr, nullptr);
    if (rc < 0 && errno == EPERM) {
        g_traced_at_load.store(true, std::memory_order_release);
    }
}

bool scan_maps_for_frida() {
    char path_buf[sizeof(kProcMapsPath.data)];
    deobfuscate(kProcMapsPath, path_buf);
    int fd = ::open(path_buf, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;

    // Stage all 6 needles into a stack-local table. Lives only for
    // the duration of this scan.
    constexpr size_t kMaxNeedleLen = 16;
    constexpr int    kNeedleCount  = 6;
    char     needles[kNeedleCount][kMaxNeedleLen]{};
    size_t   lens[kNeedleCount];
    using dash::obf::deobfuscate_into;
    deobfuscate_into(kNeedle0, needles[0], kMaxNeedleLen); lens[0] = kNeedle0.length;
    deobfuscate_into(kNeedle1, needles[1], kMaxNeedleLen); lens[1] = kNeedle1.length;
    deobfuscate_into(kNeedle2, needles[2], kMaxNeedleLen); lens[2] = kNeedle2.length;
    deobfuscate_into(kNeedle3, needles[3], kMaxNeedleLen); lens[3] = kNeedle3.length;
    deobfuscate_into(kNeedle4, needles[4], kMaxNeedleLen); lens[4] = kNeedle4.length;
    deobfuscate_into(kNeedle5, needles[5], kMaxNeedleLen); lens[5] = kNeedle5.length;

    constexpr size_t kChunk = 4096;
    constexpr size_t kOverlap = kMaxNeedleLen;
    char buf[kChunk + kOverlap];
    std::memset(buf, 0, sizeof(buf));
    size_t carry = 0;
    bool hit = false;
    while (!hit) {
        ssize_t n = ::read(fd, buf + carry, kChunk);
        if (n <= 0) break;
        size_t total = carry + static_cast<size_t>(n);
        for (int i = 0; i < kNeedleCount; ++i) {
            if (::memmem(buf, total, needles[i], lens[i]) != nullptr) {
                hit = true;
                break;
            }
        }
        if (hit) break;
        if (total > kOverlap) {
            std::memcpy(buf, buf + total - kOverlap, kOverlap);
            carry = kOverlap;
        } else {
            carry = total;
        }
    }
    ::close(fd);
    return hit;
}

// ─── JNI bridges (registered via RegisterNatives in JNI_OnLoad) ─────

jstring native_ping(JNIEnv* env, jclass /*clazz*/) {
    // Returned literal also serves as a build-stamp probe. Public; not
    // a secret. Stays unobfuscated because returning encrypted bytes
    // here would break the smoke test.
    return env->NewStringUTF("ds:ok");
}

jint native_tracer_pid(JNIEnv* /*env*/, jclass /*clazz*/) {
    char path_buf[sizeof(kProcStatusPath.data)];
    deobfuscate(kProcStatusPath, path_buf);
    auto status = read_proc_file(path_buf);
    if (status.empty()) return -1;
    char key_buf[sizeof(kTracerPidKey.data)];
    deobfuscate(kTracerPidKey, key_buf);
    return parse_tracer_pid(status, key_buf);
}

jboolean native_has_frida_in_maps(JNIEnv* /*env*/, jclass /*clazz*/) {
    return scan_maps_for_frida() ? JNI_TRUE : JNI_FALSE;
}

jboolean native_traced_at_load(JNIEnv* /*env*/, jclass /*clazz*/) {
    return g_traced_at_load.load(std::memory_order_acquire) ? JNI_TRUE
                                                            : JNI_FALSE;
}

jstring native_abi(JNIEnv* env, jclass /*clazz*/) {
#if defined(__aarch64__)
    return env->NewStringUTF("arm64-v8a");
#elif defined(__arm__)
    return env->NewStringUTF("armeabi-v7a");
#elif defined(__x86_64__)
    return env->NewStringUTF("x86_64");
#elif defined(__i386__)
    return env->NewStringUTF("x86");
#else
    return env->NewStringUTF("unknown");
#endif
}

}  // namespace

// JNI_OnLoad — the only JNIEXPORT symbol. Decodes the obfuscated class
// FQCN + method names into stack buffers, registers the native methods,
// then lets the buffers go out of scope. The plaintext class/method
// strings exist only for the duration of this function call.
extern "C" JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    snapshot_ptrace_state();

    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    char class_buf[sizeof(kClass.data)];
    deobfuscate(kClass, class_buf);
    jclass clazz = env->FindClass(class_buf);
    if (clazz == nullptr) {
        LOGW("class lookup failed");
        return JNI_ERR;
    }

    // Stage the method-name buffers. Each is alive until end of
    // JNI_OnLoad; that's when RegisterNatives's name-pointer copies
    // are no longer needed.
    char m_ping[sizeof(kMethodPing.data)];
    char m_tpid[sizeof(kMethodTracerPid.data)];
    char m_frida[sizeof(kMethodHasFrida.data)];
    char m_traced[sizeof(kMethodTraced.data)];
    char m_abi[sizeof(kMethodAbi.data)];
    deobfuscate(kMethodPing,      m_ping);
    deobfuscate(kMethodTracerPid, m_tpid);
    deobfuscate(kMethodHasFrida,  m_frida);
    deobfuscate(kMethodTraced,    m_traced);
    deobfuscate(kMethodAbi,       m_abi);

    const JNINativeMethod methods[] = {
        {m_ping,   const_cast<char*>(kSigString),
            reinterpret_cast<void*>(native_ping)},
        {m_tpid,   const_cast<char*>(kSigInt),
            reinterpret_cast<void*>(native_tracer_pid)},
        {m_frida,  const_cast<char*>(kSigBool),
            reinterpret_cast<void*>(native_has_frida_in_maps)},
        {m_traced, const_cast<char*>(kSigBool),
            reinterpret_cast<void*>(native_traced_at_load)},
        {m_abi,    const_cast<char*>(kSigString),
            reinterpret_cast<void*>(native_abi)},
    };

    jint rc = env->RegisterNatives(
        clazz, methods, sizeof(methods) / sizeof(methods[0])
    );
    if (rc != JNI_OK) {
        LOGW("RegisterNatives failed: %d", rc);
        return JNI_ERR;
    }
    return JNI_VERSION_1_6;
}
