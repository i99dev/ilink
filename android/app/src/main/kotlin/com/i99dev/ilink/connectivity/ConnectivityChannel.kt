package com.i99dev.ilink.connectivity

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Dart-facing control for the always-on "car online" keep-alive
 * ([ConnectivityService]).
 *
 * The native service is the single source of truth for the enable flag
 * (a SharedPreferences gate it reads on every start — see
 * [ConnectivityService.isEnabled]), so the Settings toggle reads + writes
 * it through here rather than keeping a second copy in Dart `AppSettings`.
 * Writes apply immediately: [ConnectivityService.setEnabled] persists the
 * pref AND starts/stops the foreground service in one call.
 *
 * Methods (mirrored in `connectivity_keepalive_bridge.dart`):
 *   - `isKeepAliveEnabled`  → Bool
 *   - `setKeepAliveEnabled` (`enabled: Bool`) → {ok: true}
 */
class ConnectivityChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "ilink/connectivity"
        private const val TAG = "ConnectivityChannel"
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    fun register() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isKeepAliveEnabled" ->
                        result.success(ConnectivityService.isEnabled(context))
                    "setKeepAliveEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        ConnectivityService.setEnabled(context, enabled)
                        result.success(mapOf("ok" to true))
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "channel error in ${call.method}: ${t.message}", t)
                result.error("connectivity_error", t.message, null)
            }
        }
    }
}
