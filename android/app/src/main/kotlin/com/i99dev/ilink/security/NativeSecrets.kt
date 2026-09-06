package com.i99dev.ilink.security

import android.util.Log

/**
 * Kotlin bridge to `libdash_secrets.so` — the native-side companion to
 * [TamperProbes]. Native methods are bound via `RegisterNatives` in the
 * library's `JNI_OnLoad` (cpp/secrets.cpp), so the only exported symbol
 * in the .so is `JNI_OnLoad` itself — `nm`, `objdump -T`, and `strings`
 * will not reveal the probe names. The Kotlin method names below are
 * authoritative and must match the table in `cpp/secrets.cpp::kMethods`.
 *
 * Safe fallback: [isAvailable] is false when the shared library fails to
 * load (mock builds, instrumentation tests, devices with an ABI we don't
 * ship, or any UnsatisfiedLinkError). Callers that prefer native paths
 * should gate on [isAvailable] and fall back to the Kotlin implementation
 * otherwise — [TamperProbes] does exactly this so the integrity monitor
 * keeps working either way.
 */
object NativeSecrets {
    private const val TAG = "NativeSecrets"
    private const val LIB = "dash_secrets"

    @Volatile private var loaded: Boolean = false

    /**
     * Captured at lib load: was a debugger/Frida already attached BEFORE
     * `System.loadLibrary` returned? `JNI_OnLoad` calls
     * `ptrace(PTRACE_TRACEME)`; on EPERM (= already traced) it sets the
     * native flag, which we cache in Kotlin so callers don't pay a JNI
     * round-trip every call. False until the lib loads.
     */
    @Volatile private var tracedAtLoadCached: Boolean = false

    init {
        loaded = try {
            System.loadLibrary(LIB)
            // Smoke test. Confirms RegisterNatives bound our table; if any
            // entry point is wrong the ping throws UnsatisfiedLinkError.
            val ping = nativePing()
            // The literal must stay in sync with cpp/secrets.cpp::native_ping.
            // It's NOT a secret — present in the .so as a string literal —
            // it's just a build-stamp.
            val ok = ping.startsWith("ds:")
            if (ok) {
                tracedAtLoadCached = nativeTracedAtLoad()
                if (tracedAtLoadCached) {
                    // Don't crash here — IntegrityMonitor decides policy. But
                    // log loudly so a debug build owner sees it.
                    Log.w(TAG, "ptrace already engaged at lib load — debugger/Frida likely attached")
                }
                Log.i(TAG, "loaded on ${nativeAbi()} (ping=$ping, traced=$tracedAtLoadCached)")
            } else {
                Log.w(TAG, "ping returned unexpected value: $ping")
            }
            ok
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "$LIB not available: ${e.message}")
            false
        } catch (e: Throwable) {
            Log.w(TAG, "$LIB init failed: ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    /** True when the native library loaded and passed the ping check. */
    val isAvailable: Boolean get() = loaded

    /** Reads /proc/self/status → TracerPid. Returns 0 when nothing
     *  attached, -1 on parse error, or null when the native side isn't
     *  available (caller falls back to the Kotlin implementation). */
    fun tracerPid(): Int? = if (loaded) nativeTracerPid() else null

    /** /proc/self/maps scan for Frida agent / gum loop substrings.
     *  Returns null when the native side isn't available. */
    fun hasFridaInMaps(): Boolean? = if (loaded) nativeHasFridaInMaps() else null

    /**
     * Was the process being ptrace'd at the moment libdash_secrets.so
     * loaded? This is a stronger signal than [tracerPid] because the
     * snapshot is taken inside `JNI_OnLoad` — before any Java code can
     * un-attach the debugger or hook our methods. Once true, stays true
     * for the life of the process (intentional — re-detach can't clear).
     * Returns null when the lib isn't loaded.
     */
    fun tracedAtLoad(): Boolean? = if (loaded) tracedAtLoadCached else null

    /** For debugging — which libdash_secrets.so ABI actually loaded. */
    fun abi(): String? = if (loaded) nativeAbi() else null

    // --- JNI entry points. Bound via RegisterNatives at JNI_OnLoad time.
    //     The names + signatures here must match cpp/secrets.cpp::kMethods
    //     byte-for-byte. Any rename needs the same rename on the C side.

    @JvmStatic private external fun nativePing(): String
    @JvmStatic private external fun nativeTracerPid(): Int
    @JvmStatic private external fun nativeHasFridaInMaps(): Boolean
    @JvmStatic private external fun nativeTracedAtLoad(): Boolean
    @JvmStatic private external fun nativeAbi(): String
}
