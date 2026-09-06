package com.i99dev.ilink.connectivity

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Resume-from-suspend watchdog. Fired by the repeating AlarmManager tick
 * scheduled in [ConnectivityService.scheduleWatchdog]. Because the alarm
 * is held by the system, this receiver runs even when our process was
 * killed during a long off period.
 *
 * NOTE on this BYD ROM: the alarm path is a SECONDARY layer. The ROM's
 * self-start guard cancels a non-whitelisted app's alarms on park, so the
 * PRIMARY revive vector is the AccessibilityService rebind (which the ROM
 * does NOT quarantine) — both a11y services call the same
 * [ConnectivityService.coldReviveIfNeeded] from onServiceConnected. This
 * receiver still helps across short standby where the alarm survives.
 *
 * Each tick:
 *   1. Stands down entirely if the driver disabled the keep-alive.
 *   2. Re-arms the next tick FIRST — the alarm is one-shot, and the re-arm
 *      MUST happen before any other gate (screen-off / already-running)
 *      can early-return, or the chain dies after the first such tick.
 *   3. Delegates the actual revive to the shared, gated, idempotent
 *      [ConnectivityService.coldReviveIfNeeded] so the alarm path and the
 *      a11y path are byte-for-byte equivalent (keep-alive pref + screen-on
 *      + process-was-dead gates, BAL-safe foreground launch).
 */
class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TICK) return

        if (!ConnectivityService.isEnabled(context)) {
            // Driver turned keep-alive off → stop the watchdog entirely.
            ConnectivityService.cancelWatchdog(context)
            return
        }

        // Re-arm FIRST so a crash or early-return inside the revive can't
        // break the chain. coldReviveIfNeeded's own gates (screen-off,
        // already-running) must never prevent the next tick from being
        // armed, or the one-shot alarm stops ticking.
        ConnectivityService.scheduleWatchdog(context)

        ConnectivityService.coldReviveIfNeeded(context, source = "watchdog")
    }

    companion object {
        const val ACTION_TICK = "com.i99dev.ilink.connectivity.WATCHDOG_TICK"
    }
}
