package com.i99dev.ilink.nav.ingest

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import com.i99dev.ilink.nav.logic.WazeArrowRegistry
import com.i99dev.ilink.nav.logic.WazeLaneCapture

/**
 * Captures Waze's maneuver arrow — drawn as a bitmap (no a11y text, no notification),
 * so it can only be read as PIXELS — via MediaProjection, and publishes a maneuver
 * code to [WazeArrowBus] for the Waze a11y nav source.
 *
 * Pipeline (ported from the reference's capture service): an AUTO_MIRROR
 * VirtualDisplay of the default display feeds an [ImageReader]; a throttled loop
 * crops the live arrow region ([WazeArrowBounds], written by the a11y service),
 * perceptual-hash matches it ([WazeArrowRegistry]) → maneuver code → bus. The
 * projection token comes from [WazeProjectionHolder] (granted once via
 * [WazeCaptureConsentActivity]); the service rebuilds the projection from it on
 * restart without re-prompting. Fully guarded — any per-frame failure leaves the
 * last code to age out of the bus, never throws.
 *
 * BYD note: we mirror the DEFAULT display only (never move a task onto a fission /
 * cluster display), so this can't trip the group-0 reshuffle hang.
 */
class WazeArrowCaptureService : Service() {

    private var projection: MediaProjection? = null
    private var reader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null
    private val thread = HandlerThread("waze-arrow").apply { start() }
    private val handler = Handler(thread.looper)
    @Volatile private var running = false
    private var bufW = 0
    private var bufH = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        // Token comes from the in-process holder (set by the consent activity), not
        // the intent — so a service restart reuses consent without a dialog.
        val proj = WazeProjectionHolder.acquire(this)
        if (proj == null) {
            Log.w(TAG, "no projection token — stopping (consent needed)")
            stopSelf()
            return START_NOT_STICKY
        }
        startProjection(proj)
        return START_STICKY
    }

    private fun startProjection(proj: MediaProjection) {
        teardownCapture() // idempotent restart
        projection = proj
        // API 34+: the stop callback MUST be registered BEFORE createVirtualDisplay,
        // or createVirtualDisplay throws. (Also our cleanup hook on revoke.)
        proj.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "projection stopped (revoked) — stopping service")
                    WazeProjectionHolder.onProjectionStopped()
                    stopSelf()
                }
            },
            handler,
        )

        val m = DisplayMetrics().also {
            @Suppress("DEPRECATION")
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(it)
        }
        bufW = m.widthPixels
        bufH = m.heightPixels
        // Reader sized at the real display → buffer coords == a11y screen coords
        // (AUTO_MIRROR mirrors 1:1 at this size); every crop is still validated.
        reader = ImageReader.newInstance(bufW, bufH, PixelFormat.RGBA_8888, 2)
        virtualDisplay = projection?.createVirtualDisplay(
            VD_NAME, bufW, bufH, m.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader?.surface, null, handler,
        )
        running = true
        handler.post(captureLoop)
        Log.e(TAG, "capture started ${bufW}x$bufH dpi=${m.densityDpi}") // DIAGNOSTIC (temp)
    }

    private val captureLoop = object : Runnable {
        override fun run() {
            if (!running) return
            runCatching { captureOnce() }.onFailure { Log.e(TAG, "capture loop: ${it.message}") }
            handler.postDelayed(this, LOOP_DELAY_MS)
        }
    }

    private fun captureOnce() {
        val image = reader?.acquireLatestImage() ?: run { Log.e(TAG, "cap: no image"); return }
        try {
            val plane = image.planes[0]
            captureArrowFrom(plane)
            captureLanesFrom(plane)
        } finally {
            image.close()
        }
    }

    private fun captureArrowFrom(plane: Image.Plane) {
        val crop = WazeArrowBounds.latest() ?: return // stale/absent → nothing to do
        // REJECT (don't clamp) an out-of-buffer rect: a clamped/partial crop
        // hashes to garbage that matches no signature. Wait for a valid frame.
        if (!ArrowCrop.isValid(crop.left, crop.top, crop.width, crop.height, bufW, bufH)) return
        val argb = ArrowCrop.extract(
            plane.buffer, plane.rowStride, plane.pixelStride,
            crop.left, crop.top, crop.width, crop.height,
        )
        val code = WazeArrowRegistry.classify(argb, crop.width, crop.height)
        if (code != null) WazeArrowBus.update(code)
    }

    private fun captureLanesFrom(plane: Image.Plane) {
        val crop = WazeLaneBounds.latest() ?: return // no lane row visible → leave it
        if (!ArrowCrop.isValid(crop.left, crop.top, crop.width, crop.height, bufW, bufH)) return
        val argb = ArrowCrop.extract(
            plane.buffer, plane.rowStride, plane.pixelStride,
            crop.left, crop.top, crop.width, crop.height,
        )
        WazeLaneBus.update(WazeLaneCapture.fromLaneRow(argb, crop.width, crop.height, density))
    }

    private val density: Float get() = resources.displayMetrics.density

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Nav-HUD capture", NotificationManager.IMPORTANCE_MIN),
            )
        }
        val n: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Nav-HUD")
            .setContentText("Mirroring navigation guidance to the cluster")
            .setSmallIcon(android.R.drawable.ic_menu_directions)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun teardownCapture() {
        running = false
        handler.removeCallbacks(captureLoop)
        runCatching { virtualDisplay?.release() }; virtualDisplay = null
        runCatching { reader?.close() }; reader = null
        // Don't stop() the projection here — the holder owns its lifetime so a
        // restart can reuse it; we only stop it on full destroy / revoke.
    }

    override fun onDestroy() {
        teardownCapture()
        runCatching { projection?.stop() }
        WazeProjectionHolder.onProjectionStopped()
        projection = null
        thread.quitSafely()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "WazeArrowCapture"
        private const val CHANNEL_ID = "waze_capture_channel"
        private const val NOTIF_ID = 202
        private const val VD_NAME = "WazeArrowCapture"
        // Turn arrows change only at maneuver transitions; ~800 ms is responsive and
        // far cheaper than per-frame hashing.
        private const val LOOP_DELAY_MS = 800L

        /** Stop the capture (Nav-HUD disarm / Waze backgrounded). */
        fun stop(ctx: Context) {
            runCatching { ctx.stopService(Intent(ctx, WazeArrowCaptureService::class.java)) }
        }
    }
}
