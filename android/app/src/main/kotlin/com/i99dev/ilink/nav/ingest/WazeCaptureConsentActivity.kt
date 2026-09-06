package com.i99dev.ilink.nav.ingest

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log

/**
 * One-time MediaProjection consent prompt for the Waze arrow capture. Transparent,
 * no UI: on create it fires the system "Start recording / casting?" dialog; on grant
 * it stores the token in [WazeProjectionHolder], starts [WazeArrowCaptureService],
 * and finishes. On decline it just finishes — the Nav-HUD keeps working without the
 * arrow (distance/road/ETA from a11y; the arrow defaults to straight). Mirrors the
 * reference's consent activity.
 *
 * Themed Theme.Translucent.NoTitleBar (manifest) so nothing flashes on screen.
 * Launched as a standalone Activity (the plugin holds the application context, and
 * MainActivity is pinned to the IVI display — we don't disturb it).
 */
class WazeCaptureConsentActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        runCatching {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            @Suppress("DEPRECATION")
            startActivityForResult(mgr.createScreenCaptureIntent(), REQ_CONSENT)
        }.onFailure {
            Log.e(TAG, "couldn't launch screen-capture consent: ${it.message}")
            finish()
        }
    }

    @Deprecated("startActivityForResult result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_CONSENT && resultCode == RESULT_OK && data != null) {
            WazeProjectionHolder.setToken(resultCode, data)
            startCapture(this)
        } else {
            Log.i(TAG, "projection consent declined — arrow capture stays off")
        }
        finish()
    }

    companion object {
        private const val TAG = "WazeConsent"
        private const val REQ_CONSENT = 0xCA

        private fun startCapture(ctx: Context) {
            runCatching {
                val svc = Intent(ctx, WazeArrowCaptureService::class.java)
                // FGS with type mediaProjection must be started foreground on 26+.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(svc)
                else ctx.startService(svc)
            }.onFailure { Log.w(TAG, "startService failed: ${it.message}") }
        }

        /** Entry point: prompt for consent, or — if already granted this process —
         *  just (re)start the capture service without showing a dialog. */
        fun request(ctx: Context) {
            if (WazeProjectionHolder.hasConsent) {
                startCapture(ctx.applicationContext)
                return
            }
            val i = Intent(ctx, WazeCaptureConsentActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { ctx.startActivity(i) }
                .onFailure { Log.w(TAG, "couldn't start consent activity: ${it.message}") }
        }
    }
}
