package com.i99dev.ilink.adb

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel that lets the Dart-side onboarding query and
 * re-trigger [AdbBootstrap].
 *
 * Two methods:
 *   * `getStatus` → status map (persistedVersion, targetVersion,
 *     lastResultKind, lastResultDetail, lastFailureCount). Cheap,
 *     read-only.
 *   * `retry` → drops the persisted version and re-runs the full
 *     grant set. Used when the cold-launch attempt hit
 *     [AdbBootstrap.Result.Skipped] (Wireless debugging not yet
 *     enabled by the user) and onboarding wants to re-try after the
 *     user flips it on. Returns the same status map.
 *
 * Threading: `retry` shells to loopback ADB which can take several
 * seconds. Offloaded to a worker thread; the Dart `Future` resolves
 * on the platform thread once the worker posts back via
 * [Handler.post].
 */
class AdbBootstrapPlugin(
    private val context: Context,
) {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(::onMethodCall)
        channel = ch
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(AdbBootstrap.getStatusMap(context))
            "retry" -> {
                Thread({
                    try {
                        AdbBootstrap.retry(context)
                        val status = AdbBootstrap.getStatusMap(context)
                        mainHandler.post { result.success(status) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error(
                                "RETRY_THREW",
                                "${t.javaClass.simpleName}: ${t.message}",
                                null,
                            )
                        }
                    }
                }, "adb-bootstrap-retry").apply { isDaemon = true }.start()
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "ilink/adb_bootstrap"
    }
}
