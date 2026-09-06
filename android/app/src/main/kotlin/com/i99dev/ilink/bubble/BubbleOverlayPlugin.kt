package com.i99dev.ilink.bubble

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Method channel that drives the [BubbleOverlayService] lifecycle.
 *
 * Methods on `ilink/bubble_overlay`:
 *   * `show(x, y)`       → start the overlay service in foreground at
 *                          screen-pixel coordinates (x, y).
 *   * `hide()`           → stop the overlay service.
 *   * `minimize()`       → call `Activity.moveTaskToBack(true)` so the
 *                          BYD launcher reappears.
 *   * `isShowing()`      → true if the service is alive in this
 *                          process.
 *
 * The plugin needs an [Activity] reference for `moveTaskToBack`
 * because that API is Activity-scoped. The reference is held weakly so
 * a stale Activity (after onDestroy) doesn't pin memory.
 */
class BubbleOverlayPlugin(
    private val context: Context,
    private val activityRef: WeakReference<Activity>,
) {
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
            "show" -> {
                val x = (call.argument<Int>("x")) ?: 0
                val y = (call.argument<Int>("y")) ?: 0
                val intent = Intent(context, BubbleOverlayService::class.java)
                    .putExtra(BubbleOverlayService.EXTRA_X, x)
                    .putExtra(BubbleOverlayService.EXTRA_Y, y)
                ContextCompat.startForegroundService(context, intent)
                result.success(true)
            }
            "hide" -> {
                context.stopService(Intent(context, BubbleOverlayService::class.java))
                result.success(true)
            }
            "minimize" -> {
                val activity = activityRef.get()
                if (activity == null) {
                    result.success(false)
                } else {
                    val ok = activity.moveTaskToBack(true)
                    result.success(ok)
                }
            }
            "isShowing" -> result.success(BubbleOverlayService.isRunning())
            // User toggle (Settings → Appearance): persist whether the floating
            // bubble may appear when backgrounded. Turning it off also tears down a
            // live bubble. Read back by MainActivity.startBubbleForBackground.
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                BubbleOverlayService.setEnabled(context, enabled)
                result.success(true)
            }
            "isEnabled" -> result.success(BubbleOverlayService.isEnabled(context))
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "ilink/bubble_overlay"
    }
}
