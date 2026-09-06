package com.i99dev.ilink.nav.ingest

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.i99dev.ilink.nav.NavHudOptions
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.NavAlertExtractor
import com.i99dev.ilink.nav.logic.NavManeuverExtractor
import com.i99dev.ilink.nav.logic.NavNotifParse

/**
 * The universal nav-notification listener. Android binds this (only if the user
 * granted notification access); for every ONGOING notification from a known nav
 * app ([NavAppRegistry]) it parses the standard extras into a [NavGuidance] and
 * emits onto [NavNotifBus]. One service → all apps.
 *
 * Capability-probed by design: no grant → never bound → the rest of the HUD
 * (a11y sources) is unaffected.
 */
class NavNotifListenerService : NotificationListenerService() {

    // Re-emit ticker: keeps a notification-driven frame FRESH while its
    // notification is still present (= navigation is live), independent of how
    // often the posting app updates it. Generic root cause this fixes: nav apps
    // re-post their notification only when the guidance changes — Google Maps can
    // go many seconds between posts while Yandex spams ~1/s — so without re-emit a
    // well-behaved app's frame ages past the arbiter TTL and the HUD clears
    // mid-navigation though nav is still running. The notification's PRESENCE is
    // the liveness signal; its removal (onNotificationRemoved) is the end signal.
    // No per-app TTL tuning, no VirtualDisplay, no a11y — works for every notif app.
    private val ticker = android.os.Handler(android.os.Looper.getMainLooper())
    private val keepFresh = object : Runnable {
        override fun run() {
            if (NavNotifBus.hasSink()) {
                runCatching { activeNotifications?.forEach { process(it) } }
            }
            ticker.postDelayed(this, KEEP_FRESH_MS)
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        ticker.removeCallbacks(keepFresh)
        ticker.postDelayed(keepFresh, KEEP_FRESH_MS)
    }

    override fun onListenerDisconnected() {
        ticker.removeCallbacks(keepFresh)
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        process(sbn ?: return)
    }

    private fun process(sbn: StatusBarNotification) {
        val app = NavAppRegistry.forPackage(sbn.packageName) ?: return
        val n = sbn.notification ?: return
        // only the persistent turn-by-turn notification, not promos/alerts
        if (n.flags and Notification.FLAG_ONGOING_EVENT == 0) return
        val e = n.extras ?: return

        // THE source of truth for the turn direction: derive the maneuver from the
        // notification (title → large-icon arrow). Publish it to the per-package
        // bus so the accessibility sources (which own distance/road) read the
        // correct arrow instead of classifying their own view-id text, which on
        // these apps doesn't carry the direction. null = couldn't decide → keep
        // the prior maneuver (bus untouched).
        val maneuver = NavManeuverExtractor.extract(sbn.packageName, n, applicationContext)
        if (maneuver != null) NavManeuverBus.set(sbn.packageName, maneuver)

        val frame = NavNotifParse.parse(
            title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            text = e.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            subText = e.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            bigText = e.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            source = app.id,
            // The notification frame uses the same derived maneuver; falls back to
            // the bus (this post may have lacked a direction a recent one had).
            maneuverOverride = maneuver ?: NavManeuverBus.latest(sbn.packageName),
        ) ?: return

        // P3: Yandex encodes camera/safety/traffic-light alerts in the notification's
        // icon resource names (not text). Attach them to the frame (gated). Yandex-only
        // — Google Maps / Waze carry no alert icons, so don't pay the scan for them.
        val out = if (NavHudOptions.cameraAlerts && app.id == NavSourceId.YANDEX) {
            val a = NavAlertExtractor.extract(sbn.packageName, n, applicationContext)
            if (a.isEmpty) frame else frame.copy(
                cameraType = a.cameraType, cameraDistance = a.cameraDistance, cameraState = a.cameraState,
                safetyType = a.safetyType, safetyDistance = a.safetyDistance, safetyState = a.safetyState,
                trafficLightColor = a.trafficLightColor, trafficLightSeconds = a.trafficLightSeconds,
            )
        } else {
            frame
        }

        NavNotifBus.emit(out)
    }

    /** A known nav app's notification was removed → navigation ended for that app.
     *  The controller starts its grace timer and clears the cluster after it. */
    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn ?: return
        val app = NavAppRegistry.forPackage(sbn.packageName) ?: return
        // Navigation ended for this app → soft-clear its maneuver with the SAME grace
        // the controller uses, so an a11y window still on-screen during the grace reads
        // the correct arrow (e.g. the arrival arrow while decelerating), not a defaulted
        // one. After the grace the code stops serving.
        NavManeuverBus.clearAfter(sbn.packageName, SOURCE_GONE_GRACE_MS)
        NavNotifBus.emitGone(app.id)
    }

    companion object {
        /** Mirrors HudController.SOURCE_GONE_GRACE_MS — the maneuver stays readable for
         *  exactly the controller's source-gone grace, then stops. */
        private const val SOURCE_GONE_GRACE_MS = 12_000L

        /** Re-emit cadence for still-present nav notifications. Kept short (sub-second)
         *  so the backgrounded distance/road tracks the live notification closely — at
         *  2 s the cluster visibly lagged when an app (Google Maps) posts sparsely. The
         *  re-read is cheap: [NavManeuverExtractor] memo-caches on the notification's
         *  text, so an unchanged post does no real work; only a changed one parses. Well
         *  under the shortest arbiter TTL (Google Maps = 5 s) either way. */
        private const val KEEP_FRESH_MS = 700L
    }
}
