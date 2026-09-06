package com.i99dev.ilink.connectivity

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.R
import com.i99dev.ilink.boot.BootCompletedReceiver
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Pure decision for [ConnectivityService.coldReviveIfNeeded]: revive the
 * dash only when the keep-alive is enabled, the car is awake (interactive),
 * and our process was previously dead (not already running). Factored out as
 * a framework-free top-level function so the full truth table is unit-testable
 * in the pure-JVM harness (no Robolectric) — see ColdReviveDecisionTest. The
 * three gates map to: driver kill-switch, 12V/parked safety, and
 * idempotency / never-interrupt-active-use.
 */
fun shouldColdRevive(enabled: Boolean, interactive: Boolean, running: Boolean): Boolean =
    enabled && interactive && !running

/**
 * Always-on "car online" keep-alive. Its single job is to anchor the
 * hosting process at foreground-service priority so the BYD head unit's
 * standby memory reclaim can't kill us.
 *
 * Why this exists — the failure it fixes:
 *   A *normal* car start does NOT reboot the head unit; it resumes it
 *   from suspend/standby (observed: ~31 h uptime across many car
 *   on/off cycles). Android only fires BOOT_COMPLETED on a true cold
 *   boot — which is the "restart the IVI" path — so the boot receiver
 *   never runs on a normal start. Meanwhile, during standby the ROM
 *   reclaims memory and kills our process; on resume there is nothing
 *   to relaunch and the car shows offline / the dash is gone until the
 *   driver taps the icon. The only time it survived was when the radio
 *   AudioService happened to hold a foreground notification — exactly
 *   the "sometimes works" symptom.
 *
 * The fix is to ALWAYS hold a foreground notification so the process
 * (and the Dart MQTT/presence isolate that is the live link to the
 * Telegram mini-app) stays resident through standby. On resume the
 * engine is already up, MQTT reconnects, MainActivity returns from
 * stopped→resumed with no relaunch, and presence never flaps.
 *
 * Design notes:
 *   - We deliberately do NOT re-host MQTT here. The connection stays in
 *     Dart (lib/app/mqtt), this service only raises process priority.
 *     Moving MQTT into a headless background FlutterEngine would be a
 *     second implementation for no extra reliability — anchoring the
 *     process is sufficient and leaves the working MQTT untouched.
 *   - START_STICKY so that if the ROM still reaps us under extreme
 *     pressure, the system recreates the service (and the process) when
 *     it can, and onStartCommand re-enters the foreground.
 *   - specialUse FGS type: the app already declares
 *     FOREGROUND_SERVICE_SPECIAL_USE (see AndroidManifest). The subtype
 *     is declared on the <service> element.
 *   - Gated by a SharedPreferences flag (default ON) so the persistent
 *     notification can be turned off without an uninstall.
 */
class ConnectivityService : Service() {

    companion object {
        private const val TAG = "ConnectivityService"
        private const val CHANNEL_ID = "dash.connectivity"
        private const val NOTIFICATION_ID = 4243

        private const val ACTION_START = "com.i99dev.ilink.connectivity.START"
        private const val ACTION_STOP = "com.i99dev.ilink.connectivity.STOP"

        /** SharedPreferences gate. Default true — the keep-alive is on
         *  unless the driver explicitly disables it. */
        private const val PREFS_NAME = "ilink.connectivity"
        private const val KEY_ENABLED = "keep_alive_enabled"

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_ENABLED, true)

        /**
         * Start the keep-alive if it's enabled. Safe to call repeatedly —
         * starting an already-foreground service just re-runs
         * onStartCommand, which re-enters the foreground idempotently.
         * No-op (and stops any running instance) when disabled.
         */
        fun startIfEnabled(context: Context) {
            if (!isEnabled(context)) {
                stop(context)
                return
            }
            val intent = Intent(context, ConnectivityService::class.java)
                .setAction(ACTION_START)
            try {
                context.startForegroundService(intent)
            } catch (t: Throwable) {
                // Background-start can be refused on some ROM/timing
                // combos (rare given our power-whitelist + FGS perms);
                // a denial just means we fall back to today's behaviour.
                Log.w(TAG, "keep-alive start refused: ${t.javaClass.simpleName}: ${t.message}")
            }
            // Always (re)arm the resume-from-suspend watchdog while
            // enabled — it's the recovery path if the FGS is later
            // reaped during a long off and there's no BOOT_COMPLETED.
            scheduleWatchdog(context)
        }

        /** Persist the on/off choice and apply it immediately. */
        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ENABLED, enabled)
                .apply()
            if (enabled) startIfEnabled(context) else stop(context)
        }

        fun stop(context: Context) {
            cancelWatchdog(context)
            val intent = Intent(context, ConnectivityService::class.java)
                .setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (_: Throwable) {
                // Service not running — nothing to stop.
            }
        }

        // ── Resume-from-suspend watchdog ──────────────────────────────
        // The FGS keeps the process resident across SHORT standby, but a
        // long off period (overnight) kills it entirely — and the IVI
        // *suspends* rather than reboots, so no BOOT_COMPLETED fires on
        // car-on to restart us (verified: ~44h uptime across many on/off
        // cycles). A repeating AlarmManager tick — held by the SYSTEM, so
        // it survives our process death — revives us on the next wake.
        //
        // Non-wakeup ELAPSED_REALTIME so we never spin the SoC up while
        // parked (12V-safe); the tick only fires once the device is
        // already awake (car on). WatchdogReceiver gates on screen-on +
        // "process was dead" before doing anything.

        /** True while the foreground service is alive in THIS process.
         *  False in a freshly-spawned process (⇒ we were killed) — that's
         *  how the watchdog tells a cold revive from a live no-op. */
        @Volatile
        private var running = false

        fun isRunning(): Boolean = running

        /** Collapses the same-wake double-fire. Both AccessibilityServices
         *  (and an overlapping alarm tick) can each pass the !isRunning()
         *  gate in the same wake, because [running] only flips true
         *  ASYNCHRONOUSLY once the FGS dispatch reaches onStartCommand. This
         *  compareAndSet guarantees exactly one revive per process spawn;
         *  reset in onDestroy so the next freshly-spawned process revives
         *  again. */
        private val reviveInFlight = AtomicBoolean(false)

        /**
         * The single, shared cold-revive entry point for every autostart
         * vector — the alarm [WatchdogReceiver], both AccessibilityServices
         * on rebind, and the boot receiver — so the gating + launch sequence
         * can never drift between them.
         *
         * Revives (start FGS + foreground the dash) only when [shouldColdRevive]
         * holds: keep-alive enabled, car awake, process was dead. Foregrounding
         * MainActivity is mandatory — the FGS alone only raises priority; MQTT /
         * presence run only once the Flutter engine executes, which needs the
         * dash foregrounded (verified on-car).
         *
         * Safe under near-simultaneous callers ([reviveInFlight]) and before
         * user-unlock (the credential-encrypted keep-alive pref read is guarded;
         * an unreadable pref means "defer", not crash — a later rebind/tick
         * retries). The Activity start is wrapped for BAL denial; the FGS start
         * runs first so we stay anchored even if the launch is refused.
         */
        fun coldReviveIfNeeded(context: Context, source: String) {
            val enabled = try {
                isEnabled(context)
            } catch (t: Throwable) {
                // Pre-unlock / direct-boot: credential storage not ready.
                Log.w(TAG, "$source: keep-alive pref unreadable (pre-unlock?) — deferring: ${t.message}")
                return
            }
            if (!enabled) return

            val interactive = try {
                (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
            } catch (t: Throwable) {
                Log.w(TAG, "$source: power state unreadable — deferring: ${t.message}")
                return
            }
            if (!shouldColdRevive(enabled = true, interactive = interactive, running = isRunning())) return

            // Close the async window before [running] flips — one revive per
            // process spawn regardless of how many vectors fire this wake.
            if (!reviveInFlight.compareAndSet(false, true)) return

            Log.i(TAG, "$source: cold revive — anchoring keep-alive + foregrounding dash")
            // Anchor first; survives even a BAL-denied Activity start. This
            // also re-arms the watchdog alarm via scheduleWatchdog.
            startIfEnabled(context)
            try {
                val launch = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
                    )
                    putExtra(BootCompletedReceiver.EXTRA_AUTOSTART, true)
                }
                context.startActivity(launch)
            } catch (t: Throwable) {
                Log.w(TAG, "$source revive launch blocked: ${t.javaClass.simpleName}: ${t.message}")
            }
        }

        private const val WATCHDOG_INTERVAL_MS = 3 * 60 * 1000L

        private fun watchdogPendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, WatchdogReceiver::class.java)
                .setAction(WatchdogReceiver.ACTION_TICK)
            return PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        /** Arm the next watchdog tick (one-shot; the receiver re-arms). */
        fun scheduleWatchdog(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            try {
                am.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME,
                    SystemClock.elapsedRealtime() + WATCHDOG_INTERVAL_MS,
                    watchdogPendingIntent(context),
                )
            } catch (t: Throwable) {
                Log.w(TAG, "watchdog schedule failed: ${t.message}")
            }
        }

        fun cancelWatchdog(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            try {
                am.cancel(watchdogPendingIntent(context))
            } catch (_: Throwable) {
                // Nothing armed.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // intent == null means the system recreated us after a kill
        // (START_STICKY). Treat that as "start" so we immediately
        // re-anchor the process.
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // A late disable (pref flipped while running) wins.
                if (!isEnabled(this)) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
                enterForeground()
            }
        }
        return START_STICKY
    }

    private fun enterForeground() {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        Log.i(TAG, "keep-alive foreground — process anchored for online presence")
    }

    override fun onDestroy() {
        // Clear the resident marker so a future watchdog tick in a
        // freshly-spawned process reads false and performs a cold revive.
        running = false
        // Re-open the once-per-process revive gate so a re-enable (or a
        // service recreate) in this same process can revive again.
        reviveInFlight.set(false)
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val tapIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ilink")
            .setContentText("Car online — reachable from your phone")
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
    }

    private fun ensureChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Car online",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description =
                    "Keeps the car reachable from the app and starts the " +
                        "dash automatically after the car wakes from standby"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }
}
