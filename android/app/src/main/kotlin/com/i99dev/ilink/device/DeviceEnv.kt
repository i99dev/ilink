package com.i99dev.ilink.device

import android.os.Build
import android.util.Log

/**
 * Runtime environment probe. Distinguishes a real car head unit from an
 * Android emulator so the handful of BYD-ROM-specific behaviours can relax on
 * a dev/emulator install WITHOUT a source patch or a build-type dependency:
 *
 *   * [com.i99dev.ilink.MainActivity] — the "primary driver == user 0"
 *     self-terminate guard (AAOS emulators run the driver as user 10).
 *   * [com.i99dev.ilink.security.IntegrityMonitor] — SignaturePin / unit-DEX
 *     tamper reporting (a debug-signed, un-staged emulator build always trips
 *     it, which would otherwise spam the backend).
 *
 * On REAL hardware every signal below is false, so production behaviour is
 * byte-for-byte unchanged — this is purely an emulator carve-out.
 *
 * Detection keys on the QEMU kernel flags the emulator sets at boot
 * (`ro.kernel.qemu` / `ro.boot.qemu`) — these are NOT among the BYD identity
 * props a developer overrides to impersonate a car, so they survive any
 * car-spoofing. Build-field heuristics are a backstop. Cached: the answer
 * cannot change within a process.
 */
object DeviceEnv {
    private const val TAG = "DeviceEnv"

    /** True iff this process is running on an Android emulator. */
    val isEmulator: Boolean by lazy { detect() }

    private fun detect(): Boolean {
        // Primary, spoof-resistant: QEMU markers set by the emulator itself.
        if (sysprop("ro.kernel.qemu") == "1" || sysprop("ro.boot.qemu") == "1") return true
        val hw = (sysprop("ro.hardware") ?: "").lowercase()
        if (hw == "ranchu" || hw == "goldfish" || hw.contains("vbox")) return true

        // Backstop: standard Build-field heuristics.
        val fp = (Build.FINGERPRINT ?: "").lowercase()
        val model = Build.MODEL ?: ""
        val product = Build.PRODUCT ?: ""
        return fp.startsWith("generic") ||
            fp.startsWith("unknown") ||
            fp.contains("emulator") ||
            fp.contains("/sdk") ||
            fp.contains("sdk_g") ||
            model.contains("Android SDK built for") ||
            model.contains("Emulator") ||
            (Build.MANUFACTURER ?: "").contains("Genymotion") ||
            product == "google_sdk" ||
            product.contains("sdk_g")
    }

    /** Reflection read of a system property (`android.os.SystemProperties` is `@hide`). */
    private fun sysprop(key: String): String? =
        try {
            val cls = Class.forName("android.os.SystemProperties")
            val m = cls.getMethod("get", String::class.java)
            (m.invoke(null, key) as? String)?.takeIf { it.isNotEmpty() }
        } catch (e: Throwable) {
            Log.d(TAG, "sysprop('$key') failed: ${e.message}")
            null
        }
}
