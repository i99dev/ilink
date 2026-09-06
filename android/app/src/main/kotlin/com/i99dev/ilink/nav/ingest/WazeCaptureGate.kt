package com.i99dev.ilink.nav.ingest

import android.content.Context
import android.os.SystemClock

/**
 * Coordinates Waze arrow capture between the a11y service (sees Waze come/go) and the
 * Nav-HUD plugin (knows armed + owns consent). The a11y service calls
 * [onWazeForeground] / [onWazeGone]; capture runs only while armed + Waze foreground
 * + consent granted. Keeps the MediaProjection (and its FGS notification) alive only
 * when it's actually useful, without the a11y service importing the plugin.
 */
object WazeCaptureGate {

    @Volatile var armed = false

    @Volatile private var lastStartMs = 0L
    @Volatile private var serviceWanted = false

    /** Called each time the a11y side sees Waze foreground (poll/event), while armed.
     *  If consent is held → (re)start the capture service once. If NOT yet held →
     *  pop the one-time system consent dialog, re-prompting at most every 8 s until
     *  granted (so the feature self-activates on first Waze nav and a missed/declined
     *  prompt isn't permanent), without per-poll dialog spam. */
    fun onWazeForeground(ctx: Context) {
        if (!armed) return
        val hasConsent = WazeProjectionHolder.hasConsent
        if (hasConsent && serviceWanted) return // service already (re)started
        val now = SystemClock.elapsedRealtime()
        val minGap = if (hasConsent) 1_500L else 8_000L // retry consent slower than restarts
        if (now - lastStartMs < minGap) return
        lastStartMs = now
        if (hasConsent) serviceWanted = true
        // request() shows the dialog when there's no token, or starts the FGS when there is.
        WazeCaptureConsentActivity.request(ctx.applicationContext)
    }

    /** Called when Waze leaves the foreground (another nav app, or nav ended). */
    fun onWazeGone(ctx: Context) {
        if (!serviceWanted) return
        serviceWanted = false
        WazeArrowCaptureService.stop(ctx.applicationContext)
        WazeArrowBounds.clear()
        WazeLaneBounds.clear()
    }
}
