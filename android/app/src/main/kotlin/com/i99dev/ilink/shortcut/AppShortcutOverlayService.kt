package com.i99dev.ilink.shortcut

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import androidx.core.app.NotificationCompat
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.R
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Hosts a set of INDEPENDENT, draggable floating app-shortcut buttons —
 * one [TYPE_APPLICATION_OVERLAY] window per pinned package. Each button
 * shows that app's launcher icon and, on tap, launches it directly (no
 * app-list navigation). Dragging persists each button's own position.
 *
 * Distinct from `BubbleOverlayService` (the single voice "chat head"):
 * this manages N buttons keyed by package and never reflects voice state.
 *
 * Runs as FOREGROUND_SERVICE_TYPE_SPECIAL_USE (Android 14+) — the matching
 * manifest declaration carries `PROPERTY_SPECIAL_USE_FGS_SUBTYPE =
 * "app_shortcut_overlay"`. SYSTEM_ALERT_WINDOW (TYPE_APPLICATION_OVERLAY) is
 * granted at runtime by AdbBootstrap; this service does NOT request it.
 */
class AppShortcutOverlayService : Service() {

    /** One pinned button: its overlay view + layout params + drag state. */
    private class Holder(val packageName: String) {
        var view: View? = null
        var params: WindowManager.LayoutParams? = null
        var initialTouchX = 0f
        var initialTouchY = 0f
        var initialParamsX = 0
        var initialParamsY = 0
        var movedDistance = 0f
    }

    private var windowManager: WindowManager? = null

    // packageName -> Holder. The live set of pinned buttons.
    private val holders = LinkedHashMap<String, Holder>()

    private var tapSlopPx = 0f

    // Self-heal: re-attach any holder whose view the WMS dropped (BYD WMS
    // drops overlays on display churn). Mirrors BubbleOverlayService's
    // watchdog but per-button.
    private val watchdog = Handler(Looper.getMainLooper())
    private val watchdogTick = object : Runnable {
        override fun run() {
            try {
                for (h in holders.values) {
                    if (h.view == null) attach(h)
                }
            } finally {
                watchdog.postDelayed(this, WATCHDOG_INTERVAL_MS)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        tapSlopPx = 12f * resources.displayMetrics.density
        watchdog.postDelayed(watchdogTick, WATCHDOG_INTERVAL_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNotificationChannel()
        startInForeground()

        // The requested pinned set. A null/empty set means "show nothing"
        // → tear down + stop. START_STICKY restarts arrive with a null
        // intent; we keep whatever holders we already have in that case.
        val requested = intent?.getStringArrayListExtra(EXTRA_PACKAGES)
        if (requested != null) reconcile(requested)

        if (holders.isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The buttons are meant to outlive the app being swiped away —
        // re-assert any the WMS tore down with the task.
        for (h in holders.values) {
            if (h.view == null) attach(h)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        watchdog.removeCallbacks(watchdogTick)
        for (h in holders.values) detach(h)
        holders.clear()
        running = false
        super.onDestroy()
    }

    /** Bring the live button set in line with [packages]: add new ones,
     *  remove dropped ones, leave unchanged ones attached. */
    private fun reconcile(packages: List<String>) {
        val pm = packageManager
        // Only keep packages that still resolve to a launchable activity.
        val wanted = packages.filter { pm.getLaunchIntentForPackage(it) != null }

        // Remove buttons no longer wanted.
        val toRemove = holders.keys.filter { it !in wanted }
        for (pkg in toRemove) {
            holders.remove(pkg)?.let { detach(it) }
        }
        // Add new buttons.
        for ((index, pkg) in wanted.withIndex()) {
            if (holders.containsKey(pkg)) continue
            val holder = Holder(pkg)
            holders[pkg] = holder
            attach(holder, indexForDefault = index)
        }
    }

    private fun attach(holder: Holder, indexForDefault: Int = -1) {
        val wm = windowManager ?: return
        val pm = packageManager
        val icon = try {
            pm.getApplicationIcon(holder.packageName)
        } catch (t: Throwable) {
            Log.w(TAG, "icon load failed for ${holder.packageName}: ${t.message}")
            null
        }

        val view = LayoutInflater.from(this)
            .inflate(R.layout.app_shortcut_button, null, false)
        view.findViewById<ImageView>(R.id.shortcut_icon)?.setImageDrawable(icon)

        val density = resources.displayMetrics.density
        val sidePx = (52f * density).toInt()
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels

        // Default resting place: a vertical stack down the RIGHT edge (so it
        // doesn't sit under the voice bubble's default left edge). Staggered
        // by index so freshly-pinned buttons don't pile on one spot. A user's
        // dragged position always wins.
        val gap = (12f * density).toInt()
        val idx = if (indexForDefault >= 0) indexForDefault else holders.size
        val defaultX = (screenW - sidePx - (8f * density)).toInt().coerceAtLeast(0)
        val defaultY = ((screenH / 4) + idx * (sidePx + gap)).coerceAtMost(
            (screenH - sidePx).coerceAtLeast(0),
        )

        val prefs = sharedPrefs(this)
        val startX = prefs.getInt(keyX(holder.packageName), Int.MIN_VALUE)
            .takeIf { it != Int.MIN_VALUE } ?: defaultX
        val startY = prefs.getInt(keyY(holder.packageName), Int.MIN_VALUE)
            .takeIf { it != Int.MIN_VALUE } ?: defaultY

        val params = WindowManager.LayoutParams(
            sidePx,
            sidePx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = startX
            y = startY
        }

        view.setOnTouchListener { _, event -> handleTouch(holder, event) }

        try {
            wm.addView(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "addView failed for ${holder.packageName}: ${t.message}")
            return
        }
        holder.view = view
        holder.params = params
    }

    private fun handleTouch(holder: Holder, event: MotionEvent): Boolean {
        val params = holder.params ?: return false
        val view = holder.view ?: return false
        val wm = windowManager ?: return false

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                holder.initialTouchX = event.rawX
                holder.initialTouchY = event.rawY
                holder.initialParamsX = params.x
                holder.initialParamsY = params.y
                holder.movedDistance = 0f
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - holder.initialTouchX
                val dy = event.rawY - holder.initialTouchY
                params.x = holder.initialParamsX + dx.toInt()
                params.y = holder.initialParamsY + dy.toInt()
                holder.movedDistance = hypot(abs(dx), abs(dy))
                try {
                    wm.updateViewLayout(view, params)
                } catch (_: Throwable) {
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (holder.movedDistance < tapSlopPx) {
                    launch(holder.packageName)
                } else {
                    persistPosition(holder.packageName, params.x, params.y)
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (holder.movedDistance >= tapSlopPx) {
                    persistPosition(holder.packageName, params.x, params.y)
                }
                return true
            }
        }
        return false
    }

    /** Open the pinned app directly on the default display. Best-effort:
     *  a missing launcher intent just logs (the button stays). */
    private fun launch(packageName: String) {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        if (intent == null) {
            Log.w(TAG, "no launcher intent for $packageName")
            return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "launch $packageName failed: ${t.message}")
        }
    }

    private fun detach(holder: Holder) {
        val wm = windowManager
        val view = holder.view
        if (wm != null && view != null) {
            try {
                wm.removeView(view)
            } catch (_: Throwable) {
            }
        }
        holder.view = null
        holder.params = null
    }

    private fun persistPosition(packageName: String, x: Int, y: Int) {
        sharedPrefs(this).edit()
            .putInt(keyX(packageName), x)
            .putInt(keyY(packageName), y)
            .apply()
    }

    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ilink app shortcuts",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while floating app shortcuts are active"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ilink shortcuts")
            .setContentText("Floating app shortcuts are active.")
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val TAG = "AppShortcutOverlay"

        const val CHANNEL_ID = "ilink_app_shortcuts"
        const val NOTIFICATION_ID = 8422
        const val EXTRA_PACKAGES = "extra_packages"

        private const val WATCHDOG_INTERVAL_MS = 3_000L
        private const val PREFS_NAME = "ilink.shortcut.positions"

        @Volatile
        private var running: Boolean = false

        fun isRunning(): Boolean = running

        private fun keyX(pkg: String) = "x.$pkg"
        private fun keyY(pkg: String) = "y.$pkg"

        private fun sharedPrefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }
}
