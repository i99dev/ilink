package com.i99dev.ilink.input

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.i99dev.ilink.connectivity.ConnectivityService

/**
 * Heartbeat-only AccessibilityService. Its sole job is to be a second
 * service the user enables alongside [RemoteControlAccessibilityService]
 * — its presence in the enabled-services list is the signal we
 * use to detect "BYD's accessibility panel forgot our settings".
 *
 * Why two services: the host has a tendency on some BYD firmwares to
 * silently disable individual accessibility services after a system
 * update. With one service, you can't distinguish "the one we need
 * is off" from "user never enabled". With two services that always
 * travel together, the asymmetric state ("watchdog enabled but
 * gesture service disabled" or vice versa) is a strong signal that
 * something flipped them.
 *
 * Same pattern i99dev ships in (per their bundled
 * `WatchdogAccessibilityService` class).
 */
class WatchdogAccessibilityService : AccessibilityService() {
    companion object {
        private const val TAG = "WatchdogA11y"

        @Volatile
        var instance: WatchdogAccessibilityService? = null
            private set

        @Volatile
        var lastHeartbeatMs: Long = 0L
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        lastHeartbeatMs = System.currentTimeMillis()
        Log.i(TAG, "onServiceConnected")
        // PRIMARY car-start revive vector. The BYD ROM re-binds this enabled
        // a11y service on resume — bypassing the BOOT_COMPLETED self-start
        // quarantine that kills the boot receiver and the cancelled alarm —
        // spawning our dead process in ~1s. Turn that bind into a full dash
        // revive. Failure-isolated so a revive throw can never break the
        // heartbeat/instance contract above. applicationContext: this process
        // may have been spawned without an Activity.
        try {
            ConnectivityService.coldReviveIfNeeded(applicationContext, source = "a11y-watchdog")
        } catch (t: Throwable) {
            Log.w(TAG, "a11y revive failed: ${t.message}")
        }
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Heartbeat once per system event; cheap because the service
        // only registers for window-state-change events (per its
        // a11y_watchdog.xml config) which fire a few times per minute.
        lastHeartbeatMs = System.currentTimeMillis()
    }

    override fun onInterrupt() {}
}
