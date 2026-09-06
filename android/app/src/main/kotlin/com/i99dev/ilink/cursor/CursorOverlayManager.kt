package com.i99dev.ilink.cursor

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * Owns a single cursor view drawn over the IVI as a TYPE_APPLICATION_OVERLAY.
 *
 * The cursor is a touchpad-style indicator: the mini-app sees the
 * IVI as a touchpad, the cursor shows where the eventual gesture
 * dispatch will land on the cluster. This view is on the IVI, NOT
 * on the cluster — drawing on the cluster is signature-gated. Same
 * pattern i99dev's `CursorOverlayManager` ships in.
 *
 * Hot path: [moveTo] runs at ~60 Hz during a drag. It's a single
 * `setX` / `setY` per call — no per-frame allocation, no
 * `windowManager.updateViewLayout` (which would re-layout). The
 * outer transparent ViewGroup is full-screen; only the inner
 * `CursorView` translates.
 */
class CursorOverlayManager(private val applicationContext: Context) {

    companion object {
        private const val TAG = "CursorOverlay"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val displayMgr: DisplayManager =
        applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

    private var cursor: CursorView? = null
    private var attached = false
    // The WindowManager we used to add `cursor` — we MUST use the
    // same one to remove it. When the cursor is bound to a non-default
    // display we hold the per-display WM here; the main `wm` is only
    // a fallback for the IVI path.
    private var attachedWm: WindowManager? = null

    /**
     * Mount the cursor view, optionally on a non-default display.
     * Returns false if the platform refuses to add the window — most
     * commonly because:
     *   * SYSTEM_ALERT_WINDOW isn't granted (AdbBootstrap v2+ usually
     *     handles this on first launch; if cold-pair window hasn't
     *     completed, caller should prompt).
     *   * The target display is owned by another app with
     *     `FLAG_OWN_CONTENT_ONLY` — Leopard 8's XDJA cluster slots
     *     fall here. We attempt the cross-display attach anyway and
     *     log the SecurityException so the mini-app falls back to
     *     in-pad CSS feedback.
     *
     * `targetDisplayId` defaults to `Display.DEFAULT_DISPLAY` (the
     * IVI). Non-default displays need a `Context.createDisplayContext`
     * + per-display WindowManager — without that the overlay always
     * lands on the default display regardless of what the caller
     * asked for.
     */
    fun attach(style: String, targetDisplayId: Int = 0): Boolean {
        if (attached) {
            cursor?.setStyle(style)
            return true
        }
        var ok = false
        runOnMainBlocking {
            try {
                // Per-display Context + WindowManager so the overlay
                // lands on the requested display. `createDisplayContext`
                // is the standard cross-display window pattern; without
                // it `applicationContext.WindowManager` always targets
                // the default display.
                val target = displayMgr.getDisplay(targetDisplayId)
                val ctx = if (target != null && targetDisplayId != 0) {
                    applicationContext.createDisplayContext(target)
                } else {
                    applicationContext
                }
                val targetWm = ctx
                    .getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val v = CursorView(ctx).apply { setStyle(style) }
                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT,
                ).apply { gravity = Gravity.START or Gravity.TOP }
                targetWm.addView(v, params)
                cursor = v
                attachedWm = targetWm
                attached = true
                ok = true
            } catch (t: Throwable) {
                Log.w(TAG, "attach to display=$targetDisplayId failed: ${t.message}")
            }
        }
        return ok
    }

    fun detach() {
        runOnMainBlocking {
            cursor?.let {
                try { attachedWm?.removeView(it) } catch (t: Throwable) {
                    Log.w(TAG, "removeView threw: ${t.message}")
                }
            }
            cursor = null
            attachedWm = null
            attached = false
        }
    }

    fun moveTo(x: Float, y: Float) {
        // Hot path. Already on main if invoked from a Flutter
        // platform-channel callback; if not, post — Views require it.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            cursor?.moveTo(x, y)
        } else {
            mainHandler.post { cursor?.moveTo(x, y) }
        }
    }

    fun setStyle(style: String) {
        runOnMainBlocking { cursor?.setStyle(style) }
    }

    fun dispose() {
        detach()
    }

    private fun runOnMainBlocking(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            val lock = Object()
            var done = false
            mainHandler.post {
                try { block() } finally {
                    synchronized(lock) { done = true; lock.notifyAll() }
                }
            }
            synchronized(lock) {
                while (!done) lock.wait()
            }
        }
    }
}

/**
 * Single-shot cursor View. Three styles:
 *  * `dot`  — solid 16dp circle.
 *  * `glow` — radial-fade 48dp blob.
 *  * `ring` — 24dp open ring with 3dp stroke.
 */
@SuppressLint("ViewConstructor")
private class CursorView(context: Context) : View(context) {

    private val density: Float = resources.displayMetrics.density
    private var styleName: String = "dot"
    private var cx: Float = -1000f
    private var cy: Float = -1000f

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f * density
    }

    fun setStyle(name: String) {
        styleName = name
        invalidate()
    }

    fun moveTo(x: Float, y: Float) {
        cx = x
        cy = y
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (cx < 0 || cy < 0) return
        when (styleName) {
            "ring" -> {
                strokePaint.color = Color.argb(220, 255, 255, 255)
                canvas.drawCircle(cx, cy, 12f * density, strokePaint)
            }
            "glow" -> {
                fillPaint.color = Color.argb(80, 88, 199, 255)
                canvas.drawCircle(cx, cy, 24f * density, fillPaint)
                fillPaint.color = Color.argb(180, 200, 168, 255)
                canvas.drawCircle(cx, cy, 8f * density, fillPaint)
            }
            else -> {
                // dot
                fillPaint.color = Color.argb(220, 255, 255, 255)
                canvas.drawCircle(cx, cy, 8f * density, fillPaint)
            }
        }
    }
}
