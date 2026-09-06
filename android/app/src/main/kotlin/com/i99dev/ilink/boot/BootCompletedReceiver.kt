package com.i99dev.ilink.boot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.connectivity.ConnectivityService

/**
 * Triggered by the system on `android.intent.action.BOOT_COMPLETED`
 * (and the LOCKED_BOOT_COMPLETED variant on direct-boot capable
 * devices). Does two things:
 *
 *   1. Writes a one-shot SharedPreferences flag the Flutter side
 *      reads on first MainActivity launch so [BootStore]'s
 *      `boot.write` replay can run.
 *   2. Launches [MainActivity] so the Flutter engine boots and the
 *      app-layer subsystems (MQTT, presence heartbeat, voice prewarm,
 *      OTA orchestrator) come up automatically when the car powers
 *      on. Without (2) the receiver writes the flag, the process
 *      stays "empty", Android kills it within ~4 s, and MQTT never
 *      connects — so the cloud + miniapp see the car as offline
 *      until the user manually taps the icon. (Observed 2026-05-15
 *      after a 6-hour car-off period: device booted, receiver fired,
 *      process killed at adj 975, miniapp stayed offline for hours.)
 *
 * The startActivity call uses ``FLAG_ACTIVITY_NEW_TASK`` because we're
 * outside an Activity stack here, plus ``FLAG_INCLUDE_STOPPED_PACKAGES``
 * isn't needed — the receiver firing already means our package isn't
 * stopped. We deliberately do NOT pass ``FLAG_ACTIVITY_NO_HISTORY`` /
 * ``FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS`` so the user can swipe to /
 * away from the dash like any normal app.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }
        val now = System.currentTimeMillis()
        Log.i(TAG, "boot complete @ $now — staging boot.write replay + launching host")
        // Default SharedPreferences file matches what shared_preferences
        // Flutter package reads when configured with the
        // FlutterSharedPreferences instance name. main.dart reads
        // this key and clears it after running BootLauncher.
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putLong(PENDING_KEY, now)
            .apply()

        // Anchor the process immediately via the keep-alive FGS, before
        // (and independent of) the activity launch below. If a ROM blocks
        // the background-Activity start, the keep-alive still keeps us
        // resident so MQTT/presence comes up and resume-from-standby
        // doesn't strand us. No-op when the driver disabled it.
        ConnectivityService.startIfEnabled(context)

        // Launch the host so the Flutter engine boots → app-layer
        // subsystems wire up → MQTT connects → cloud + miniapp see
        // the car as online without requiring the user to tap the
        // icon. Wrapped in try/catch because some Android variants
        // restrict background-Activity starts (Android 10+ has the
        // `BAL_ALLOW_*` rules); on a denial we still fall back to
        // the "user-launched" path — at least the boot flag was
        // written so the replay fires when they DO open the app.
        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
                )
                putExtra(EXTRA_AUTOSTART, true)
            }
            context.startActivity(launchIntent)
            Log.i(TAG, "host activity started from boot receiver")
        } catch (t: Throwable) {
            Log.w(TAG, "host autostart blocked: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    companion object {
        private const val TAG = "BootCompletedReceiver"

        /** SharedPreferences file name. The Flutter side reads via
         *  the `shared_preferences` package configured to use this
         *  exact instance — see lib/features/mini_apps/boot/boot_launcher.dart. */
        const val PREFS_NAME = "ilink.boot"

        /** Epoch-millis of the last boot that staged a replay. The
         *  Dart side compares this to the current boot epoch
         *  (`now() - elapsedRealtime`) to detect "did we already
         *  run for this boot?" and clears it once the launches are
         *  fired. */
        const val PENDING_KEY = "pending_boot_at_ms"

        /** Intent extra so the Flutter side can tell "I launched this
         *  myself via tap" vs "BOOT_COMPLETED auto-launched me". The
         *  latter may want to skip surfaces that demand foreground
         *  attention (e.g. auto-open the home page, NOT the rename
         *  sheet). Currently informational only; main.dart consumers
         *  can pick it up via the intent flags. */
        const val EXTRA_AUTOSTART = "ilink.autostart"
    }
}
