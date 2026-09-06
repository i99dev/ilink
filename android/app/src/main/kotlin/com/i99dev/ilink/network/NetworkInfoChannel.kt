package com.i99dev.ilink.network

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.i99dev.ilink.adb.AdbShellBridge
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * MethodChannel exposing low-level network info that connectivity_plus
 * doesn't surface — chiefly the active cellular generation
 * (2G / 3G / 4G / 5G).
 *
 * The Flutter side stays platform-agnostic via a `try/catch (e:
 * MissingPluginException)` so iOS / web builds (which never call
 * [register]) gracefully receive null.
 *
 * Network-mode override (`get/setPreferredNetworkMode`):
 *   * App code can't call [TelephonyManager.setPreferredNetworkType]
 *     directly — that needs MODIFY_PHONE_STATE, a signature/system
 *     permission. So we route through the shell-UID loopback ADB
 *     bridge (the same channel that drives car features) and write
 *     `Settings.Global.preferred_network_mode` — shell normally has
 *     WRITE_SECURE_SETTINGS for `settings put`, and the radio reads
 *     that key on reload.
 *   * Confirmed against `.secrets/research/l8/.../settings_global.txt`:
 *     the Leopard 8 uses the standard key names. Per-SIM numbered
 *     keys (`preferred_network_mode1`, `..3`) are written too because
 *     the device's stock UI seems to.
 *   * Reliability is best-effort. Some ROMs ignore the change until a
 *     radio reload (airplane-mode toggle / reboot). The setter
 *     returns the readback so the UI can surface "wrote N, ROM read
 *     back M" as a soft warning when the value didn't stick.
 */
class NetworkInfoChannel(private val context: Context) {
    private var channel: MethodChannel? = null

    /** Dedicated single-threaded executor for the channel's blocking
     *  ops (shell-bridge round-trips, `Thread.sleep` between retries).
     *
     *  Critical: MethodChannel handlers run on the Flutter UI thread by
     *  default. The set-mode path can block multiple seconds (3 writes
     *  × up to 2 retries × ~3 s shell timeout + 150 ms sleep between
     *  retries). Running that synchronously on the UI thread triggers
     *  Android's input-dispatch ANR (5 s threshold) — observed in the
     *  field as `INPUT_DISPATCH_NO_FOCUSED_WINDOW` after rapid taps on
     *  the Network sheet. Single-threaded so concurrent get/set calls
     *  serialize through the same bridge session, which matches the
     *  bridge's own one-call-at-a-time locking. */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "NetworkInfoChannel-worker").apply { isDaemon = true }
    }

    /** Handler on the main looper so we can post `result.success/error`
     *  back to the right thread. MethodChannel.Result MUST be invoked
     *  on the platform thread Flutter expects (main on Android). */
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(::onMethodCall)
        channel = ch
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCellularGeneration" -> runAsync(result) { getCellularGeneration() }
            "getPreferredNetworkMode" -> runAsync(result) { getPreferredNetworkMode() }
            "setPreferredNetworkMode" -> {
                val mode = call.argument<Int>("mode")
                if (mode == null) {
                    result.error("BAD_ARG", "mode required (int)", null)
                } else {
                    runAsync(result) { setPreferredNetworkMode(mode) }
                }
            }
            "forceApplyNetworkMode" -> {
                val mode = call.argument<Int>("mode")
                val bitmask = call.argument<Int>("bitmask")
                if (mode == null || bitmask == null) {
                    result.error("BAD_ARG", "mode + bitmask required (int)", null)
                } else {
                    runAsync(result) { forceApplyNetworkMode(mode, bitmask) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Hop off the UI thread for the blocking work, then post the
     *  result back. Catching `Throwable` is intentional — we never
     *  want a bridge-side IOException or NPE to crash the Flutter
     *  engine; the Dart side has its own MissingPluginException /
     *  PlatformException fallbacks for "channel unreachable." */
    private fun runAsync(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val out: Any? = try {
                work()
            } catch (t: Throwable) {
                Log.w(TAG, "channel work threw: ${t.javaClass.simpleName}: ${t.message}")
                mainHandler.post {
                    result.error(
                        "CHANNEL_WORK_FAILED",
                        t.message ?: t.javaClass.simpleName,
                        null,
                    )
                }
                return@execute
            }
            mainHandler.post { result.success(out) }
        }
    }

    /**
     * Read `Settings.Global.preferred_network_mode` via shell — using the
     * shell-UID loopback ADB route the rest of the app already uses for
     * privileged car operations. Returns the integer mode, or null when
     * the read failed (shell not reachable, key not set, etc.).
     *
     * `preferred_network_mode` values map to TelephonyManager.NETWORK_MODE_*:
     *   0  = WCDMA preferred (3G+2G auto)        9  = LTE+3G+2G (4G auto)
     *   1  = GSM only (2G only)                  11 = LTE only (4G only)
     *   2  = WCDMA only (3G only)                36 = NR+LTE+3G+2G (5G+ auto)
     *   3  = GSM+UMTS (3G+2G auto)
     */
    private fun getPreferredNetworkMode(): Int? = readbackPreferredMode()

    /**
     * Write `Settings.Global.preferred_network_mode` via shell.
     *
     * Best-effort: also writes the per-subscription numbered keys
     * (`preferred_network_mode1`, `..3`) since some BYD ROMs read
     * those alongside the unnumbered key — captured in
     * `.secrets/research/l8/.../settings_global.txt`. The numbered
     * keys typically default to 1 (2G-only) on the L8; rewriting them
     * matches what the device's own UI seems to do when the user
     * changes the radio mode.
     *
     * Returns a small map for the Flutter side to surface in the UI:
     *   `{ ok: bool, value: int?, error: String? }`. The radio reload
     *   isn't forced — most ROMs pick up the change within a few
     *   seconds; if it doesn't apply, the user can toggle airplane
     *   mode or the OS sometimes requires a reboot.
     */
    private fun setPreferredNetworkMode(mode: Int): Map<String, Any?> {
        // Split the writes across separate shell() invocations instead
        // of a single `&&` chain. Why: the loopback ADB connection can
        // drop mid-call (logcat shows `AdbShellBridge: shell reconnect:
        // Socket closed` periodically when the persistent session has
        // been idle). With a chain, one transient blink fails all 4
        // operations including the readback, and the UI reports "ROM
        // reverted" even though the write likely succeeded. Per-call
        // invocation lets AdbShellBridge's built-in reconnect re-arm
        // between commands, and we can retry each individually.
        //
        // Primary key is `preferred_network_mode`. The numbered
        // per-SIM keys are written best-effort — some BYD ROMs read
        // them, but their absence doesn't break the radio reload.
        val writeOk = writeWithRetry(
            "settings put global preferred_network_mode $mode"
        )
        // Best-effort numbered-key writes. Failures here don't fail
        // the call — the unnumbered key is what the framework reads.
        writeWithRetry("settings put global preferred_network_mode1 $mode")
        writeWithRetry("settings put global preferred_network_mode3 $mode")

        val readback = readbackPreferredMode()
        val ok = readback == mode
        val error = when {
            ok -> null
            !writeOk -> "shell bridge unavailable (try again)"
            readback == null -> "wrote $mode, readback failed"
            else -> "wrote $mode, ROM read back $readback"
        }
        return mapOf("ok" to ok, "value" to readback, "error" to error)
    }

    /**
     * Force [mode] onto the radio for real.
     *
     * [setPreferredNetworkMode] only writes the stored
     * `Settings.Global.preferred_network_mode` preference and hopes
     * the ROM reloads — on BYD it frequently doesn't until an
     * airplane-mode toggle / reboot. This instead drives
     * `cmd phone set-allowed-network-types-for-users -s <slot>
     * <bitmask-as-binary-digits>` — the exact arg form verified
     * working on the DiLink5.0 L5 2026-05-16 (decimal/hex/no-`-s`
     * are rejected). `cmd phone` runs in the shell context,
     * which holds the `MODIFY_PHONE_STATE`-class privilege the app
     * lacks, and calls `setAllowedNetworkTypesForReason` — applied
     * to the modem immediately, with NO airplane-mode reload (so the
     * loopback ADB bridge never drops mid-op, unlike a toggle path).
     *
     * The stored-preference writes are still issued so the picker
     * highlight + the `settings get` poller stay coherent with what
     * the user chose.
     *
     * Fallback: if the ROM refuses the headless command (locked /
     * older `TelephonyShellCommand`), launch the
     * `com.android.phone` RadioInfo Activity over the same shell
     * bridge — `am start` from the shell UID bypasses the Activity's
     * export check (the same privileged-by-proxy trick the pkg
     * launcher uses), so the user can apply the mode by hand. The
     * `*#*#4636#*#*` secret code is NOT registered on this ROM, so
     * explicit-component launch is the only route.
     *
     * Returns `{ ok, path, value, allowed, error }` where
     * `path` ∈ `modem` | `radioinfo-activity` | `reverted`.
     */
    private fun forceApplyNetworkMode(mode: Int, bitmask: Int): Map<String, Any?> {
        // 1. Keep the stored preference coherent (same writes as
        //    setPreferredNetworkMode; numbered keys best-effort).
        writeWithRetry("settings put global preferred_network_mode $mode")
        writeWithRetry("settings put global preferred_network_mode1 $mode")
        writeWithRetry("settings put global preferred_network_mode3 $mode")

        // 2. The real force — privileged headless modem apply.
        //    ROM-specific arg form, verified on DiLink5.0 2026-05-16
        //    (reversibly tested + restored): the bitmask MUST be a
        //    base-2 digit STRING and the slot MUST be explicit `-s`.
        //    Decimal (`54151`), hex (`0xD387`), `0b…`, and no-`-s`
        //    are ALL rejected ("No valid NETWORK_TYPES_BITMASK" /
        //    "failed"); only `-s <slot> <binarydigits>` → "completed".
        val slot = firstLoadedSimSlot()
        val binMask = Integer.toBinaryString(bitmask)
        val setOut = shellWithRetry(
            "cmd phone set-allowed-network-types-for-users -s $slot $binMask"
        )
        val settingsValue = readbackPreferredMode()

        if (cmdPhoneApplied(setOut)) {
            val allowed = AdbShellBridge.shell(
                "cmd phone get-allowed-network-types-for-users",
                timeoutMs = 3_000,
            ).trim()
            return mapOf(
                "ok" to true,
                "path" to "modem",
                "value" to settingsValue,
                "allowed" to allowed.takeIf { !it.startsWith(BRIDGE_ERROR_PREFIX) },
                "error" to null,
            )
        }

        // 3. Headless refused → RadioInfo Activity fallback.
        val amOut = AdbShellBridge.shell(
            "am start -n $RADIOINFO_COMPONENT",
            timeoutMs = 3_000,
        )
        val radioInfoOpened = !amOut.startsWith(BRIDGE_ERROR_PREFIX) &&
            !amOut.contains("Error", ignoreCase = true) &&
            !amOut.contains("Exception", ignoreCase = true)
        return mapOf(
            "ok" to false,
            "path" to if (radioInfoOpened) "radioinfo-activity" else "reverted",
            "value" to settingsValue,
            "allowed" to null,
            "error" to if (radioInfoOpened) {
                "headless force refused — opened Phone Info to apply by hand"
            } else {
                "headless force refused, RadioInfo unavailable: ${setOut.take(160)}"
            },
        )
    }

    /** Resolve the SIM slot for the privileged network-type setter.
     *  `cmd phone set-allowed-network-types-for-users` requires an
     *  explicit `-s <slot>` on this ROM (no-slot is rejected).
     *  `gsm.sim.state` is comma-separated per slot (e.g.
     *  `LOADED,ABSENT`); target the first LOADED slot, default 0
     *  when unreadable. */
    private fun firstLoadedSimSlot(): Int {
        val s = AdbShellBridge.shell("getprop gsm.sim.state", timeoutMs = 3_000)
        if (s.startsWith(BRIDGE_ERROR_PREFIX)) return 0
        val idx = s.trim().split(",")
            .indexOfFirst { it.contains("LOADED", ignoreCase = true) }
        return if (idx >= 0) idx else 0
    }

    /** Shell-with-retry that returns the trimmed output (the
     *  existing [writeWithRetry] is Boolean / settings-put-shaped;
     *  the cmd-phone force path needs to classify the output text).
     *  Same idle-bridge re-arm pause as [writeWithRetry]. */
    private fun shellWithRetry(cmd: String): String {
        var out = ""
        repeat(2) { attempt ->
            out = AdbShellBridge.shell(cmd, timeoutMs = 3_000).trim()
            if (!out.startsWith(BRIDGE_ERROR_PREFIX)) return out
            if (attempt == 0) Thread.sleep(150)
        }
        return out
    }

    /** On this ROM the setter prints `completed` on success and
     *  `No valid NETWORK_TYPES_BITMASK` / `failed` / an exception on
     *  failure (verified 2026-05-16). We whitelist "no failure
     *  token" rather than requiring `completed`, so a ROM that
     *  prints nothing on success still reads as applied. */
    private fun cmdPhoneApplied(out: String): Boolean =
        !out.startsWith(BRIDGE_ERROR_PREFIX) &&
            !out.contains("Exception", ignoreCase = true) &&
            !out.contains("Unknown command", ignoreCase = true) &&
            !out.contains("NETWORK_TYPES_BITMASK", ignoreCase = true) &&
            !out.contains("not found", ignoreCase = true) &&
            !out.contains("failed", ignoreCase = true) &&
            !out.contains("Error while", ignoreCase = true)

    /** True when the write returned a value that doesn't start with
     *  [BRIDGE_ERROR_PREFIX] (the convention AdbShellBridge uses for
     *  its own failure modes — "Error: bridge busy …",
     *  "Error: shell reconnect failed", etc.). One retry after a brief
     *  pause covers the common case where the persistent loopback
     *  session was idle-dropped and needs re-arming. */
    private fun writeWithRetry(cmd: String): Boolean {
        repeat(2) { attempt ->
            val out = AdbShellBridge.shell(cmd, timeoutMs = 3_000)
            if (!out.startsWith(BRIDGE_ERROR_PREFIX)) return true
            if (attempt == 0) {
                Thread.sleep(150) // let the bridge reconnect quietly
            }
        }
        return false
    }

    /** Returns the current `preferred_network_mode` int, or null when
     *  the bridge fails or the key is unset. Standalone so the setter
     *  + getter share one read path. */
    private fun readbackPreferredMode(): Int? {
        repeat(2) { attempt ->
            val out = AdbShellBridge.shell(
                "settings get global preferred_network_mode",
                timeoutMs = 3_000,
            ).trim()
            if (!out.startsWith(BRIDGE_ERROR_PREFIX) && out != "null" && out.isNotEmpty()) {
                return out.toIntOrNull()
            }
            if (attempt == 0) Thread.sleep(150)
        }
        return null
    }

    /**
     * Returns one of: `"2g"`, `"3g"`, `"4g"`, `"5g"`, or null when
     * the active data network isn't cellular (Wi-Fi only, no SIM,
     * permission denied, etc.). The caller decides what to render —
     * this method intentionally avoids any UI strings so localisation
     * stays Dart-side.
     */
    private fun getCellularGeneration(): String? {
        // READ_PHONE_STATE check is technically only required on
        // pre-Android-Q devices — the modern getDataNetworkType()
        // call uses READ_BASIC_PHONE_STATE which is install-granted
        // — but the permission denial path is identical on both, so
        // we keep one branch here.
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED
        // Modern API path: getDataNetworkType doesn't require the
        // legacy permission on Android 9+; check below shields the
        // older devices.
        if (!granted && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
            as? TelephonyManager ?: return null
        val networkType = try {
            // dataNetworkType is the radio actively carrying data.
            // voiceNetworkType is the call radio — different on dual-
            // SIM phones using a 2G voice + 4G data split, so picking
            // dataNetworkType matches what the user perceives as
            // "their internet."
            tm.dataNetworkType
        } catch (_: SecurityException) {
            return null
        }
        return classifyNetworkType(networkType)
    }

    /**
     * Map of TelephonyManager.NETWORK_TYPE_* to the four user-facing
     * generations. Reference: Android source's TelephonyManager.java
     * `NETWORK_CLASS_*` constants. Treat HSPA+ / EVDO_B as 3G even
     * though carriers sometimes brand them "3.5G" — the line is
     * wherever a normal user would say "I'm on 3G."
     */
    private fun classifyNetworkType(type: Int): String? {
        return when (type) {
            TelephonyManager.NETWORK_TYPE_NR -> "5g"
            TelephonyManager.NETWORK_TYPE_LTE -> "4g"
            TelephonyManager.NETWORK_TYPE_HSPAP,
            TelephonyManager.NETWORK_TYPE_HSPA,
            TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_UMTS,
            TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A,
            TelephonyManager.NETWORK_TYPE_EVDO_B,
            TelephonyManager.NETWORK_TYPE_EHRPD,
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3g"
            TelephonyManager.NETWORK_TYPE_GPRS,
            TelephonyManager.NETWORK_TYPE_EDGE,
            TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT,
            TelephonyManager.NETWORK_TYPE_IDEN,
            TelephonyManager.NETWORK_TYPE_GSM -> "2g"
            else -> null
        }
    }

    companion object {
        const val CHANNEL = "ilink/network_info"
        private const val TAG = "NetworkInfoChannel"

        /** Hidden framework "Phone info" testing Activity. Confirmed
         *  present on the DiLink5.0 L5 (`com.android.phone` =
         *  `/system/priv-app/TeleService`); filter is
         *  MAIN+DEVELOPMENT_PREFERENCE so explicit-component launch
         *  via the shell UID is the only route (no LAUNCHER entry,
         *  4636 secret code not registered on this ROM). Runs in the
         *  phone process → can set the network type for real. */
        private const val RADIOINFO_COMPONENT =
            "com.android.phone/.settings.RadioInfo"
        /** Prefix [AdbShellBridge.shell] uses on its own failure modes
         *  (bridge not init'd, busy, reconnect failed). Lets callers
         *  distinguish a real device error from a shell-layer transient
         *  without depending on exact message strings. */
        private const val BRIDGE_ERROR_PREFIX = "Error: "
    }
}
