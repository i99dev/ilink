package com.i99dev.ilink.boot

import android.content.Context
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phase C — `boot.write` cold-start replay support.
 *
 * MethodChannel `ilink/boot` exposes two methods to the Dart
 * [BootLauncher]:
 *
 *   * `bootState()` returns
 *     `{bootEpochMs: <ms>, pendingAtMs: <ms or 0>}`.
 *     `bootEpochMs` is `System.currentTimeMillis() -
 *     SystemClock.elapsedRealtime()`, the wall-clock instant the
 *     device booted. Comparing this to a stored "last replayed
 *     boot epoch" tells us whether we've already replayed for the
 *     current boot. `pendingAtMs` is the value [BootCompletedReceiver]
 *     wrote on `BOOT_COMPLETED`; non-zero means a replay was
 *     staged. Either signal is sufficient — the receiver gives
 *     a tighter "we definitely booted" cue, the bootEpoch handles
 *     systems where the receiver was suppressed (BAL-restricted
 *     vendor builds).
 *
 *   * `clearPending()` clears the receiver's flag once the Dart
 *     replay has fired its launches successfully. Idempotent.
 *
 * Threading: methods run on Flutter's MethodChannel thread. They
 * touch SharedPreferences only (cheap, on-device IO), no shell
 * exec.
 */
class BootPlatformPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "bootState" -> result.success(handleBootState())
                "clearPending" -> {
                    handleClearPending()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "${call.method} threw: ${t.javaClass.simpleName}: ${t.message}")
            result.error("boot_native_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun handleBootState(): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val realtime = SystemClock.elapsedRealtime()
        val bootEpoch = now - realtime
        val prefs = context.getSharedPreferences(
            BootCompletedReceiver.PREFS_NAME, Context.MODE_PRIVATE,
        )
        val pending = prefs.getLong(BootCompletedReceiver.PENDING_KEY, 0L)
        return mapOf(
            "bootEpochMs" to bootEpoch,
            "pendingAtMs" to pending,
        )
    }

    private fun handleClearPending() {
        val prefs = context.getSharedPreferences(
            BootCompletedReceiver.PREFS_NAME, Context.MODE_PRIVATE,
        )
        prefs.edit().remove(BootCompletedReceiver.PENDING_KEY).apply()
    }

    companion object {
        private const val TAG = "BootPlatformPlugin"
        private const val CHANNEL = "ilink/boot"
    }
}
