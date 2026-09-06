package com.i99dev.ilink.cursor

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `cursor` family — MethodChannel adapter for attach / detach /
 * move / style. Delegates to [CursorOverlayManager], which owns the
 * single cursor view.
 *
 * Wire shape (matches `CursorNativeBridge.dart`):
 *
 *     attach({ targetDisplayId, style }) -> Bool   // ok=true on add
 *     detach()                          -> null
 *     move({ x, y })                    -> null    // hot path
 *     style(style: String)              -> null
 *
 * `targetDisplayId` is metadata only — the cursor view is always on
 * the IVI's default display because XDJA gates the cluster. The
 * mini-app uses targetDisplayId on the Dart/JS side to pick which
 * display the eventual `gesture.dispatch` should land on.
 */
class CursorPlatformPlugin(
    applicationContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val mgr = CursorOverlayManager(applicationContext)
    private val methodChannel = MethodChannel(messenger, "ilink/cursor").also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attach" -> {
                val style = call.argument<String>("style") ?: "dot"
                // targetDisplayId is now load-bearing: the manager
                // routes the overlay onto the requested display via
                // `Context.createDisplayContext` + per-display
                // WindowManager. Defaults to 0 (IVI) for legacy
                // callers that pass nothing.
                val targetDisplayId = call.argument<Int>("targetDisplayId") ?: 0
                val ok = mgr.attach(style, targetDisplayId)
                result.success(ok)
            }
            "detach" -> {
                mgr.detach()
                result.success(null)
            }
            "move" -> {
                val x = (call.argument<Number>("x"))?.toFloat()
                val y = (call.argument<Number>("y"))?.toFloat()
                if (x == null || y == null) {
                    result.error("bad_request", "x, y required", null)
                    return
                }
                mgr.moveTo(x, y)
                result.success(null)
            }
            "style" -> {
                val s = call.argument<String>("style") ?: "dot"
                mgr.setStyle(s)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        mgr.dispose()
        methodChannel.setMethodCallHandler(null)
    }
}
