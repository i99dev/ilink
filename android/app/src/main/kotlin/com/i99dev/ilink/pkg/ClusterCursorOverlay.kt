package com.i99dev.ilink.pkg

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * Cluster-side pointer indicator. Driver can't see the IVI trackpad
 * while they're looking at the cluster, so we render a small dot on
 * the cluster display that follows their finger — they see where
 * the tap will land before tapping.
 *
 * Implementation: a `TYPE_APPLICATION_OVERLAY` window placed on the
 * resolved cluster display via `createDisplayContext(display)`'s
 * own WindowManager. Position is updated by `updateViewLayout`, no
 * Surface re-creation per move. All WM ops run on the main thread
 * (post via [main]). Idempotent show / move while shown / safe hide
 * → no per-call addView churn.
 *
 * SYSTEM_ALERT_WINDOW is already granted at runtime (the bubble
 * overlay uses it). [show] no-ops cleanly if it isn't, so this
 * never crashes the pad — the user just doesn't see the cursor.
 */
object ClusterCursorOverlay {
    private const val TAG = "ClusterCursorOverlay"
    private const val SIZE_DP = 28
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var view: View? = null
    @Volatile private var wm: WindowManager? = null
    @Volatile private var params: WindowManager.LayoutParams? = null
    // Source coord space — the dimensions the IVI sends `move(x,y)` in
    // (the trackpad maps onto the app's resolved input window, so this
    // is e.g. display 3's touchableRegion on Di5.1/L8).
    @Volatile private var srcW = 0
    @Volatile private var srcH = 0
    // Destination coord space — the actual pixel dimensions of the
    // display we render the cursor on (e.g. Di5.1 cursor lands on
    // layer 4 per `cursorRemap`; its pixel size MAY differ from the
    // source layer the IVI knows about, and `move` must scale to keep
    // the dot under the finger). We resolve the real size at `show`
    // time and freeze it for the cursor's lifetime — display geometry
    // doesn't change without a recreate.
    @Volatile private var destW = 0
    @Volatile private var destH = 0
    @Volatile private var halfPx = 0

    /** Render the cursor at the centre of the cluster window.
     *
     *  [width] / [height] are the coordinate space the caller's
     *  subsequent `move(x, y)` calls operate in (typically the
     *  resolved input window's touchableRegion, e.g. 1920×720 on
     *  Di5.1/L8). The overlay's `LayoutParams.x/y` are placed
     *  DIRECTLY in that space — no scaling against the destination
     *  `Display.getRealSize`. Earlier we scaled to handle the case
     *  where the cursor's display had different pixel extents than
     *  the source, but on Di5.1 the cursor renders on display 5 (a
     *  1920×720 surface, same as the source layer 3) while the tap
     *  is injected on display 3 (also 1920×720). If we scaled the
     *  cursor against display 5's real size and the tap doesn't
     *  scale (it's an absolute `input -d` coord on display 3), the
     *  two end at different visible positions on the projected
     *  cluster. Using source coords for both keeps them aligned. */
    fun show(ctx: Context, displayId: Int, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.canDrawOverlays(ctx)
        ) {
            Log.w(TAG, "no SYSTEM_ALERT_WINDOW — cursor disabled")
            return
        }
        main.post {
            try {
                hideUnlocked()
                val display = (
                    ctx.getSystemService(Context.DISPLAY_SERVICE)
                        as DisplayManager
                    ).getDisplay(displayId) ?: return@post
                val displayCtx = ctx.applicationContext.createDisplayContext(display)
                val sidePx = (SIZE_DP * displayCtx.resources.displayMetrics.density)
                    .toInt()
                halfPx = sidePx / 2
                srcW = width
                srcH = height
                // Resolve the destination display's actual pixel
                // extent. The IVI sends `move(x, y)` in source coord
                // space (the touchableRegion the resolver reported,
                // typically 1920×720); if the cursor's destination
                // display has a different real pixel size, we scale
                // (x, y) into that space — otherwise the cursor
                // would clip at e.g. x=1920 on a wider display and
                // never reach the right edge. The TAP path (raw
                // `input -d` on the input-window display) goes
                // through the XDJA projection so its visible
                // position is also display-5-pixel-sized; the same
                // proportional scaling here keeps cursor + tap
                // aligned at every position, not just the centre.
                //
                // Fallback: if `getRealSize` returns 0×0 (some BYD
                // ROMs do that on XDJA-owned layers queried too
                // early), use the source dims — identity scale,
                // which matches the pre-resolve behaviour and is
                // never worse than what we had.
                val pt = Point()
                @Suppress("DEPRECATION")
                display.getRealSize(pt)
                destW = if (pt.x > 0) pt.x else width
                destH = if (pt.y > 0) pt.y else height
                Log.i(
                    TAG,
                    "show: src=${srcW}x${srcH} dest(display $displayId)=" +
                        "${destW}x${destH} scale=" +
                        "(${"%.3f".format(destW.toFloat() / srcW)}, " +
                        "${"%.3f".format(destH.toFloat() / srcH)})",
                )
                val v = View(displayCtx).apply {
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(Color.argb(0xCC, 0x1E, 0x88, 0xE5))
                        setStroke(
                            (2 * displayCtx.resources.displayMetrics.density).toInt(),
                            Color.WHITE,
                        )
                    }
                }
                val lp = WindowManager.LayoutParams(
                    sidePx,
                    sidePx,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT,
                ).apply {
                    gravity = Gravity.TOP or Gravity.START
                    x = (destW / 2) - halfPx
                    y = (destH / 2) - halfPx
                }
                val mgr = displayCtx.getSystemService(Context.WINDOW_SERVICE)
                    as WindowManager
                mgr.addView(v, lp)
                view = v
                params = lp
                wm = mgr
            } catch (t: Throwable) {
                Log.w(TAG, "show failed: ${t.javaClass.simpleName}: ${t.message}")
                hideUnlocked()
            }
        }
    }

    /** Move the cursor to source-space coords [x],[y] (clamped to the
     *  source range, then scaled into the destination display's pixel
     *  space). When source and destination dimensions match the
     *  scale is identity (cheap multiply, no precision loss). */
    fun move(x: Int, y: Int) {
        main.post {
            val v = view ?: return@post
            val mgr = wm ?: return@post
            val lp = params ?: return@post
            val sw = srcW
            val sh = srcH
            val dw = destW
            val dh = destH
            if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return@post
            // Clamp first, scale second — preserves the IVI's intent
            // even when its source-space dims are slightly off from
            // what the resolver returned (a one-pixel rounding error
            // shouldn't push the dot off-screen).
            val cx = x.coerceIn(0, sw - 1)
            val cy = y.coerceIn(0, sh - 1)
            val tx = (cx.toFloat() * dw / sw).toInt().coerceIn(0, dw - 1)
            val ty = (cy.toFloat() * dh / sh).toInt().coerceIn(0, dh - 1)
            lp.x = tx - halfPx
            lp.y = ty - halfPx
            try {
                mgr.updateViewLayout(v, lp)
            } catch (t: Throwable) {
                Log.w(TAG, "move failed: ${t.javaClass.simpleName}: ${t.message}")
                hideUnlocked()
            }
        }
    }

    /** Remove the cursor. Idempotent. */
    fun hide() {
        main.post { hideUnlocked() }
    }

    private fun hideUnlocked() {
        val v = view
        val mgr = wm
        view = null
        wm = null
        params = null
        if (v != null && mgr != null) {
            try {
                mgr.removeView(v)
            } catch (_: Throwable) {
                // Already detached / window torn down — ignore.
            }
        }
    }
}
