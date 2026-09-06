// String obfuscation primitives for libdash_secrets.so.
//
// Strings that name what we're checking for (Frida agent names,
// /proc paths, ptrace, the registered Java class name, the registered
// native method names) provide an attacker with a step-by-step bypass
// roadmap. This header XOR-encodes those literals at COMPILE TIME so
// the .rodata section contains only obfuscated bytes; plaintext lives
// in stack buffers for the brief window where it's used.
//
// What this is NOT: cryptographic protection. A determined attacker
// can deobfuscate any string given the binary plus the per-build XOR
// key — both are co-located in the .so. The point is to defeat the
// trivial `strings libdash_secrets.so | grep frida` workflow, raising
// the cost of locating bypass targets from "1 second" to "either run
// the binary and dump deobfuscated strings, or read disassembly to
// find the XOR key and replay."
//
// Build option: the XOR key is hardcoded here. Changing it on each
// release rotates the obfuscated bytes in the binary so attackers
// who memoise our key from one APK can't reuse the answer on the
// next one. (Out of scope for now; one byte every release.)

#ifndef DASH_OBFUSCATION_H
#define DASH_OBFUSCATION_H

#include <array>
#include <cstdint>
#include <cstddef>

namespace dash::obf {

// Per-build XOR key. The value is uninteresting on its own — finding
// it in the binary is trivial — but rotating it forces an attacker
// who scripted "deobfuscate strings" against last release to redo
// the work for each new build.
inline constexpr uint8_t XOR_KEY = 0x4D;

// Compile-time XOR'd byte array. Use with OBF(s) below.
template <size_t N>
struct ObfBytes {
    std::array<uint8_t, N> data;
    size_t length = N - 1;  // strip trailing NUL for memmem-style use
    constexpr ObfBytes(const char (&s)[N]) : data{} {
        for (size_t i = 0; i < N; ++i) {
            data[i] = static_cast<uint8_t>(s[i]) ^ XOR_KEY;
        }
    }
};

// CTAD helper so callsites read `OBF("frida-agent")` rather than
// `OBF<11>(...)`.
template <size_t N>
ObfBytes(const char (&)[N]) -> ObfBytes<N>;

// Decode an ObfBytes<N> into a stack buffer of identical size.
template <size_t N>
inline void deobfuscate(const ObfBytes<N>& src, char (&dst)[N]) {
    for (size_t i = 0; i < N; ++i) {
        dst[i] = static_cast<char>(src.data[i] ^ XOR_KEY);
    }
}

// Decode into a larger buffer. Useful when a uniformly-sized scratch
// table holds needles of varying lengths. Writes `src.length` bytes
// starting at dst[0]; the destination MUST be large enough. Does NOT
// write a NUL terminator (caller knows the length via src.length).
template <size_t N>
inline void deobfuscate_into(const ObfBytes<N>& src, char* dst,
                             size_t dst_capacity) {
    const size_t n = (src.length < dst_capacity) ? src.length : dst_capacity;
    for (size_t i = 0; i < n; ++i) {
        dst[i] = static_cast<char>(src.data[i] ^ XOR_KEY);
    }
}

// Convenience: declare an obfuscated string literal at namespace scope.
//
//   OBF_STR(kFridaAgent, "frida-agent");
//
// expands to a `constexpr ObfBytes<12> kFridaAgent{"frida-agent"};`
// — the `.rodata` of the resulting .so contains the XOR'd bytes only.
#define OBF_STR(NAME, LITERAL) \
    constexpr ::dash::obf::ObfBytes NAME{LITERAL}

// Convenience: deobfuscate to a stack buffer named BUF, then run BLOCK
// with `BUF` and `BUF##_len` available. The stack buffer is alive only
// inside BLOCK so the plaintext doesn't outlive the use site.
//
//   OBF_USE(kFridaAgent, plain) {
//       if (memmem(haystack, hlen, plain, plain_len) != nullptr) hit = true;
//   }
#define OBF_USE(SRC, BUF) \
    char BUF[sizeof((SRC).data)]; \
    ::dash::obf::deobfuscate((SRC), BUF); \
    const size_t BUF##_len = (SRC).length; \
    (void)BUF##_len; /* suppress unused-warning when BLOCK doesn't use len */

}  // namespace dash::obf

#endif  // DASH_OBFUSCATION_H
