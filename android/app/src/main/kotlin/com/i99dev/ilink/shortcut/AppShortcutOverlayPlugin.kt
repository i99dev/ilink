package com.i99dev.ilink.shortcut

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel driving [AppShortcutOverlayService].
 *
 * Methods on `ilink/app_shortcuts`:
 *   * `set(packages: List<String>)` → start/update the overlay so exactly
 *      these packages have a floating button. An empty list stops the
 *      service (no buttons).
 *   * `clear()`     → stop the overlay service.
 *   * `isShowing()` → true if the service is alive in this process.
 */
class AppShortcutOverlayPlugin(private val context: Context) {
    private var channel: MethodChannel? = null

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
            "set" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                if (packages.isEmpty()) {
                    context.stopService(
                        Intent(context, AppShortcutOverlayService::class.java),
                    )
                    result.success(false)
                    return
                }
                val intent = Intent(context, AppShortcutOverlayService::class.java)
                    .putStringArrayListExtra(
                        AppShortcutOverlayService.EXTRA_PACKAGES,
                        ArrayList(packages),
                    )
                ContextCompat.startForegroundService(context, intent)
                result.success(true)
            }
            "clear" -> {
                context.stopService(
                    Intent(context, AppShortcutOverlayService::class.java),
                )
                result.success(true)
            }
            "isShowing" -> result.success(AppShortcutOverlayService.isRunning())
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "ilink/app_shortcuts"
    }
}
