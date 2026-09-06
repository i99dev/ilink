package com.i99dev.ilink.bubble

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
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
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.ImageView
import androidx.core.app.NotificationCompat
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.R
import com.i99dev.ilink.voice.VoiceActivityState
import com.i99dev.ilink.voice.VoicePhase
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Foreground service that hosts a draggable WindowManager overlay (the
 * "chat head") while the app is in the background. Tapping the bubble
 * brings MainActivity back to the foreground; dragging it persists its
 * final position so the next session restores it where the user left
 * off.
 *
 * Runs as FOREGROUND_SERVICE_TYPE_SPECIAL_USE (Android 14+) — the
 * matching manifest declaration carries the
 * `PROPERTY_SPECIAL_USE_FGS_SUBTYPE = "bubble_overlay"` property.
 *
 * SYSTEM_ALERT_WINDOW (TYPE_APPLICATION_OVERLAY) is granted at runtime
 * by AdbBootstrap v6+; this service does NOT request it.
 */
class BubbleOverlayService : Service() {

    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    // The one-shot appear (fade-in) animator.
    private var bubbleAnimator: Animator? = null

    // Earcon player + the last phase we sounded, so we play a tone on
    // transitions only (never repeat the same phase's tone). Lazily created,
    // released in onDestroy.
    private var toneGenerator: ToneGenerator? = null
    private var lastEarconPhase: VoicePhase = VoicePhase.idle

    // The looping "listening" pulse — runs ONLY while a voice session is
    // active (driven by VoiceActivityState), never all the time. Held
    // separately so it can be cancelled the instant the session ends or
    // the overlay is removed; a leaked infinite animator on a detached
    // view would keep a Choreographer callback alive forever.
    private var pulseAnimator: Animator? = null

    // Drag tracking — set on ACTION_DOWN, consumed on subsequent moves
    // to compute deltas. Accumulated movement distance lets us classify
    // ACTION_UP as either a tap (< slop) or a drag (>= slop).
    private var initialTouchX = 0f
    private var initialTouchY = 0f
    private var initialParamsX = 0
    private var initialParamsY = 0
    private var movedDistance = 0f
    private var tapSlopPx = 0f

    // True once the overlay has been attached at least once. The
    // watchdog only RE-attaches a lost view — it never tries the very
    // first attach. On a device that fundamentally can't host an
    // overlay, attachBubble() stopSelf()s; gating on this stops a
    // START_STICKY restart loop from thrashing addView forever.
    private var everAttached = false

    // Self-heal loop. The service can outlive its WindowManager view
    // (BYD WMS drops it on display churn) or keep the view while a
    // late HIDE_NON_SYSTEM_OVERLAY_WINDOWS blocker zeroes its alpha.
    // The one-shot sweep in onStartCommand can't catch a blocker that
    // appears AFTER first attach, so re-check periodically. Strictly
    // gated on !suspended so it never fights the multi-window
    // SUSPEND/RESUME dance (that path is SurfaceFlinger-fragile).
    private val watchdog = Handler(Looper.getMainLooper())
    private var watchTicks = 0
    private val watchdogTick = object : Runnable {
        override fun run() {
            try {
                if (!suspended) {
                    if (everAttached && bubbleView == null) {
                        Log.i(TAG, "watchdog: view lost — re-attaching")
                        attachBubble(requestedX = 0, requestedY = 0)
                    } else if (bubbleView != null &&
                        ++watchTicks % SWEEP_EVERY_TICKS == 0
                    ) {
                        // Off the main thread — sweep() shells dumpsys.
                        Thread({
                            try {
                                OverlayHealthGuard.sweep()
                            } catch (_: Throwable) {
                            }
                        }, "OverlayHealthGuard-rescan")
                            .apply { isDaemon = true }
                            .start()
                    }
                }
            } finally {
                watchdog.postDelayed(this, WATCHDOG_INTERVAL_MS)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // True once startForeground() has succeeded for this service
    // instance, so onCreate + onStartCommand don't double-foreground and
    // a re-entrant start is a no-op.
    private var foregrounded = false

    override fun onCreate() {
        super.onCreate()
        running = true
        // Enter the foreground at the EARLIEST main-thread callback.
        // onStartCommand (the previous sole call site) can be delivered
        // well after onCreate when the main thread is congested — exactly
        // what happens as the app is pushed to the background while a
        // cast app comes forward. Android 12+ then kills the whole app
        // with ForegroundServiceDidNotStartInTimeException if
        // startForeground() isn't called within ~5s of
        // startForegroundService(). Foregrounding here closes that race
        // (operator-reported crash dragging an app — e.g. Yandex Navi —
        // onto the cluster, 2026-06-16).
        startInForeground()
        tapSlopPx = 12f * resources.displayMetrics.density
        watchdog.postDelayed(watchdogTick, WATCHDOG_INTERVAL_MS)
        // Reflect the voice phase on the bubble (glyph + pulse + earcon)
        // only while a session is live. The signal can fire on any thread —
        // marshal to the main thread before touching the view. `watchdog`
        // is a main-looper Handler.
        VoiceActivityState.setListener { phase, tool ->
            watchdog.post { onVoicePhaseChanged(phase, tool) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Idempotent — onCreate already foregrounded on the initial
        // create; this covers the START_STICKY restart + ACTION_* re-
        // delivers (where onCreate does not run again).
        startInForeground()

        // Respect the user's "Show floating button" toggle (Settings → Appearance).
        // THIS is the single choke for every start path — MainActivity's
        // background-start, the in-app minimize button (show/showAndMinimize), and
        // the START_STICKY restart — so disabling here guarantees the bubble never
        // attaches regardless of caller. (startInForeground ran first to satisfy the
        // startForegroundService contract before we stopSelf.) SUSPEND is allowed
        // through since it only drops the view.
        if (!isEnabled(this) && intent?.action != ACTION_SUSPEND) {
            removeOverlay()
            stopSelf()
            return START_NOT_STICKY
        }

        // Defensive sweep before the first attach. If a stuck system
        // ResolverActivity (or similar) is alive carrying
        // HIDE_NON_SYSTEM_OVERLAY_WINDOWS, our addView would succeed
        // but paint with alpha=0.0 — a silent failure. The sweep runs
        // off the main thread because it shells dumpsys; only the
        // initial-show path needs it (suspend / resume already had a
        // working overlay so the policy state is known good).
        if (intent?.action == null && bubbleView == null && !suspended) {
            Thread({
                try {
                    val cleared = OverlayHealthGuard.sweep()
                    if (cleared > 0) {
                        Log.i(TAG, "overlay health: cleared $cleared stuck blocker(s)")
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "sweep threw: ${t.message}")
                }
            }, "OverlayHealthGuard-sweep").apply { isDaemon = true }.start()
        }

        when (intent?.action) {
            ACTION_SUSPEND -> {
                // Multi-window dock incoming — the WMS is about to
                // re-parent MainActivity and our TYPE_APPLICATION_OVERLAY
                // window pointing at the full default display would
                // create an inconsistent surface graph (BYD WMS
                // sometimes panics SurfaceFlinger in this state). Drop
                // the overlay view but keep the foreground notification
                // alive so the service doesn't get killed and is ready
                // to re-attach immediately on RESUME.
                removeOverlay()
                suspended = true
            }
            ACTION_RESUME -> {
                suspended = false
                if (bubbleView == null) {
                    attachBubble(requestedX = 0, requestedY = 0)
                }
            }
            else -> {
                if (!suspended && bubbleView == null) {
                    attachBubble(
                        requestedX = intent?.getIntExtra(EXTRA_X, 0) ?: 0,
                        requestedY = intent?.getIntExtra(EXTRA_Y, 0) ?: 0,
                    )
                }
            }
        }
        // Sticky: the whole point is "always reachable in the
        // background". If the OS reaps us under memory pressure, it
        // recreates the service with a null intent — onStartCommand's
        // `else` branch then re-attaches the bubble (sweep + attach,
        // gated on !suspended). Previously START_NOT_STICKY meant a
        // single low-memory kill silently removed the bubble until the
        // app was reopened.
        return START_STICKY
    }

    /**
     * The user swiped the app off recents. We deliberately keep going:
     * the bubble's job is precisely to survive the app being gone from
     * the foreground. Re-assert the overlay if WMS tore it down with
     * the task (only when not mid multi-window suspension).
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!suspended && everAttached && bubbleView == null) {
            attachBubble(requestedX = 0, requestedY = 0)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        VoiceActivityState.setListener(null)
        watchdog.removeCallbacks(watchdogTick)
        detachBubble()
        try {
            toneGenerator?.release()
        } catch (_: Throwable) {
        }
        toneGenerator = null
        running = false
        super.onDestroy()
    }

    private fun startInForeground() {
        if (foregrounded) return
        try {
            ensureNotificationChannel()
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
            foregrounded = true
        } catch (t: Throwable) {
            // e.g. ForegroundServiceStartNotAllowedException on a
            // transient background-start restriction. Bail cleanly
            // instead of leaving a half-started FGS for the OS to reap —
            // the bubble just won't show this time, which is far better
            // than taking the whole app down.
            Log.w(TAG, "startForeground failed: ${t.javaClass.simpleName}: ${t.message}")
            stopSelf()
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ilink bubble",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while the floating ilink bubble is active"
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
        // TODO localize when shipping.
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("ilink running")
            .setContentText("Tap the floating bubble to return.")
            .setContentIntent(pending)
            .addAction(0, "Open", pending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
    }

    // requestedX/requestedY are retained for call-site compatibility
    // but no longer seed the position: the resting place is now a
    // fixed default (middle of the left edge). A user's dragged
    // position still persists and wins.
    @Suppress("UNUSED_PARAMETER")
    private fun attachBubble(requestedX: Int, requestedY: Int) {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = LayoutInflater.from(this)
            .inflate(R.layout.bubble_overlay_view, null, false)

        val prefs = sharedPrefs(this)
        val density = resources.displayMetrics.density
        val sidePx = (44f * density).toInt()

        // Default resting place: the MIDDLE of the LEFT edge. The old
        // default seeded off the top-bar button / top-left, and a
        // stale dragged position could strand it at the bottom. The
        // window is gravity TOP|START so x grows right, y grows down;
        // y = (screenH - bubble) / 2 centres it vertically, x = a
        // hair off the edge (clear of the panel's rounded corners).
        val screenH = resources.displayMetrics.heightPixels
        val defaultX = (4f * density).toInt()
        val defaultY = ((screenH - sidePx) / 2).coerceAtLeast(0)

        // One-time position reset: drop any pre-existing saved
        // position so installs that were stuck at the bottom adopt
        // the new middle-left default. Future user drags persist and
        // bump the version, so this never re-fires on them.
        if (prefs.getInt(KEY_POS_VERSION, 1) < POS_VERSION) {
            prefs.edit()
                .remove(KEY_LAST_X)
                .remove(KEY_LAST_Y)
                .putInt(KEY_POS_VERSION, POS_VERSION)
                .apply()
        }

        val startX = prefs.getInt(KEY_LAST_X, Int.MIN_VALUE)
            .takeIf { it != Int.MIN_VALUE } ?: defaultX
        val startY = prefs.getInt(KEY_LAST_Y, Int.MIN_VALUE)
            .takeIf { it != Int.MIN_VALUE } ?: defaultY

        // Explicit pixel dimensions instead of WRAP_CONTENT. WRAP_CONTENT
        // on a TYPE_APPLICATION_OVERLAY window measures with
        // MeasureSpec.UNSPECIFIED, which lets the view grow to its
        // intrinsic content size — for an ImageView referencing the
        // 108dp ic_launcher_foreground adaptive-icon foreground, that
        // means the bubble inflated to ~108dp regardless of the
        // FrameLayout's `layout_width="44dp"` declaration. Forcing
        // the window to exact 44dp pixels keeps the bubble at the
        // intended size on every density. (sidePx is computed above.)
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

        view.setOnTouchListener { _, event -> handleTouch(event) }

        try {
            wm.addView(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "addView failed: ${t.javaClass.simpleName}: ${t.message}")
            stopSelf()
            return
        }

        windowManager = wm
        bubbleView = view
        layoutParams = params
        everAttached = true
        startAppearAnimation(view)
    }

    /**
     * Quiet appear: a quick fade-in when the bubble shows (the app was just
     * minimised). Deliberately NOT an attention-grabbing motion — the
     * bubble only *pulses* when there's something to signal (an active
     * voice session). If a session is already live when it appears (the
     * user minimised mid-session), the pulse kicks in immediately.
     *
     * Pivot is set to the view centre after layout (so the pulse scales
     * about the middle); the view is held at alpha 0 until then so the
     * pre-layout frame never flashes.
     */
    private fun startAppearAnimation(view: View) {
        bubbleAnimator?.cancel()
        bubbleAnimator = null
        pulseAnimator?.cancel()
        pulseAnimator = null
        view.alpha = 0f
        view.scaleX = 1f
        view.scaleY = 1f
        view.post {
            if (bubbleView !== view) return@post // torn down before layout
            view.pivotX = view.width / 2f
            view.pivotY = view.height / 2f
            val fadeIn = ObjectAnimator.ofFloat(view, View.ALPHA, 0f, 1f)
                .setDuration(220)
            bubbleAnimator = fadeIn
            fadeIn.start()
            // Reflect any in-flight session (glyph + pulse). Seed the earcon
            // baseline to the current phase so re-attaching the bubble mid-
            // session doesn't replay a tone.
            lastEarconPhase = VoiceActivityState.phase
            setPhaseGlyph(view, VoiceActivityState.phase, VoiceActivityState.toolName)
            if (VoiceActivityState.isActive) startVoicePulse(view)
        }
    }

    /** React to a voice phase change while the bubble is up: swap the glyph
     *  so the driver can tell what the assistant is doing, run/stop the
     *  pulse, and sound a short earcon on the transition. Because the bubble
     *  only exists while the app is backgrounded, all of this is inherently
     *  background-only — the foreground UI already shows the same state. */
    private fun onVoicePhaseChanged(phase: VoicePhase, tool: String?) {
        val view = bubbleView ?: return
        setPhaseGlyph(view, phase, tool)
        if (phase != VoicePhase.idle) startVoicePulse(view) else stopVoicePulse(view)
        fireEarcon(phase)
    }

    /** Glyph per phase: a command-in-flight wins (tool icon), then error,
     *  speaking (bars), thinking/connecting (dots), listening (mic); idle
     *  restores the launcher foreground. No-op if the icon view is missing. */
    private fun setPhaseGlyph(view: View, phase: VoicePhase, tool: String?) {
        val icon = view.findViewById<ImageView>(R.id.bubble_icon) ?: return
        val res = when {
            phase == VoicePhase.tool || tool != null -> R.drawable.ic_bubble_tool
            phase == VoicePhase.error -> R.drawable.ic_bubble_error
            phase == VoicePhase.speaking -> R.drawable.ic_bubble_speaking
            phase == VoicePhase.thinking || phase == VoicePhase.connecting ->
                R.drawable.ic_bubble_thinking
            phase == VoicePhase.listening -> R.drawable.ic_bubble_mic
            else -> R.drawable.ic_launcher_foreground
        }
        icon.setImageResource(res)
    }

    /** Short, driver-safe audio cue on a phase transition (heard without
     *  looking): a chime when listening opens, an ack when a command fires,
     *  an error tone, and a done tone when the session ends. Same-phase
     *  repeats are skipped. Plays on the notification stream so it ducks
     *  under TTS rather than stealing the voice session's focus. */
    private fun fireEarcon(phase: VoicePhase) {
        if (phase == lastEarconPhase) return
        val prev = lastEarconPhase
        lastEarconPhase = phase
        val tone = when (phase) {
            VoicePhase.listening ->
                if (prev == VoicePhase.idle || prev == VoicePhase.connecting) {
                    ToneGenerator.TONE_PROP_BEEP
                } else {
                    null
                }
            VoicePhase.tool -> ToneGenerator.TONE_PROP_ACK
            VoicePhase.error -> ToneGenerator.TONE_SUP_ERROR
            VoicePhase.idle ->
                if (prev != VoicePhase.idle && prev != VoicePhase.error) {
                    ToneGenerator.TONE_PROP_BEEP2
                } else {
                    null
                }
            else -> null
        } ?: return
        playTone(tone)
    }

    private fun playTone(toneType: Int) {
        try {
            val tg = toneGenerator
                ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, EARCON_VOLUME)
                    .also { toneGenerator = it }
            tg.startTone(toneType, EARCON_DURATION_MS)
        } catch (t: Throwable) {
            Log.w(TAG, "earcon failed: ${t.message}")
        }
    }

    /**
     * The "listening" pulse — runs ONLY while a voice session is active.
     * A pronounced scale + fade throb (1.0 ↔ 0.6 scale, 1.0 ↔ 0.5 alpha)
     * so it's unmistakable at a glance that the assistant is working.
     * Stays at/below 1.0 scale, so it never clips the fixed-size window.
     */
    private fun startVoicePulse(view: View) {
        pulseAnimator?.cancel()
        view.pivotX = view.width / 2f
        view.pivotY = view.height / 2f
        val scaleX = ObjectAnimator.ofFloat(view, View.SCALE_X, 1f, 0.6f)
        val scaleY = ObjectAnimator.ofFloat(view, View.SCALE_Y, 1f, 0.6f)
        val alpha = ObjectAnimator.ofFloat(view, View.ALPHA, 1f, 0.5f)
        for (a in listOf(scaleX, scaleY, alpha)) {
            a.duration = 600
            a.repeatCount = ObjectAnimator.INFINITE
            a.repeatMode = ObjectAnimator.REVERSE
            a.interpolator = AccelerateDecelerateInterpolator()
        }
        val loop = AnimatorSet().apply { playTogether(scaleX, scaleY, alpha) }
        pulseAnimator = loop
        loop.start()
    }

    /** Stop the pulse and settle back to the resting (full, opaque) state. */
    private fun stopVoicePulse(view: View) {
        pulseAnimator?.cancel()
        pulseAnimator = null
        view.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(200).start()
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        val params = layoutParams ?: return false
        val view = bubbleView ?: return false
        val wm = windowManager ?: return false

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                initialTouchX = event.rawX
                initialTouchY = event.rawY
                initialParamsX = params.x
                initialParamsY = params.y
                movedDistance = 0f
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - initialTouchX
                val dy = event.rawY - initialTouchY
                params.x = initialParamsX + dx.toInt()
                params.y = initialParamsY + dy.toInt()
                movedDistance = hypot(abs(dx), abs(dy))
                try {
                    wm.updateViewLayout(view, params)
                } catch (_: Throwable) {
                    // View may have been detached underneath us; ignore.
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (movedDistance < tapSlopPx) {
                    onBubbleTap()
                } else {
                    persistPosition(params.x, params.y)
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (movedDistance >= tapSlopPx) {
                    persistPosition(params.x, params.y)
                }
                return true
            }
        }
        return false
    }

    private fun onBubbleTap() {
        val launch = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(launch)
        } catch (t: Throwable) {
            Log.w(TAG, "bubble tap launch failed: ${t.message}")
        }
        stopSelf()
    }

    private fun persistPosition(x: Int, y: Int) {
        sharedPrefs(this).edit()
            .putInt(KEY_LAST_X, x)
            .putInt(KEY_LAST_Y, y)
            .apply()
    }

    private fun detachBubble() {
        removeOverlay()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) { /* may be pre-Q on a stale state; ignore */ }
    }

    /// Drops the WindowManager view without stopping the foreground
    /// notification. Used by ACTION_SUSPEND so the service can keep
    /// its FGS slot through a multi-window transition and re-attach
    /// the overlay on RESUME without the OS killing us in between.
    private fun removeOverlay() {
        bubbleAnimator?.cancel()
        bubbleAnimator = null
        pulseAnimator?.cancel()
        pulseAnimator = null
        val wm = windowManager
        val view = bubbleView
        if (wm != null && view != null) {
            try {
                wm.removeView(view)
            } catch (_: Throwable) {
                // Already detached or never attached. Don't crash.
            }
        }
        bubbleView = null
        windowManager = null
        layoutParams = null
    }

    companion object {
        private const val TAG = "BubbleOverlayService"

        const val CHANNEL_ID = "ilink_bubble"
        const val NOTIFICATION_ID = 8421

        const val EXTRA_X = "extra_x"
        const val EXTRA_Y = "extra_y"

        // Self-heal cadence. 3s is responsive enough that a dropped
        // bubble pops back almost immediately without measurable
        // wakeup cost. The dumpsys-backed blocker re-sweep is heavier
        // (shells out), so it only runs every SWEEP_EVERY_TICKS ticks
        // (~12s) and only while a view is actually attached.
        private const val WATCHDOG_INTERVAL_MS = 3_000L
        private const val SWEEP_EVERY_TICKS = 4

        // Earcon volume (0-100) + per-tone duration. Moderate volume so the
        // cue is audible over road noise without overpowering TTS.
        private const val EARCON_VOLUME = 70
        private const val EARCON_DURATION_MS = 150

        // Action intents for multi-window-aware overlay control.
        // SUSPEND drops the WindowManager view (keeps FGS alive);
        // RESUME re-attaches at the persisted position. MainActivity's
        // onMultiWindowModeChanged routes through these so the overlay
        // gets out of WMS's way during the dock transition.
        const val ACTION_SUSPEND = "com.i99dev.ilink.bubble.ACTION_SUSPEND"
        const val ACTION_RESUME = "com.i99dev.ilink.bubble.ACTION_RESUME"

        private const val PREFS_NAME = "ilink.bubble.position"
        private const val KEY_LAST_X = "last_x"
        private const val KEY_LAST_Y = "last_y"

        // User toggle (Settings → Appearance): may the floating bubble show when
        // the app is backgrounded? Default true (shown). Persisted natively so
        // MainActivity.onStop can honour it even on a fresh process before Flutter
        // has pushed anything. Survives restarts.
        private const val KEY_ENABLED = "enabled"

        /** Whether the floating bubble is allowed to show in the background. */
        fun isEnabled(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_ENABLED, true)

        /** Persist the user's choice; when turning OFF, also tear down a live bubble. */
        fun setEnabled(ctx: Context, enabled: Boolean) {
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (!enabled) {
                ctx.stopService(Intent(ctx, BubbleOverlayService::class.java))
            }
        }

        // Bumped when the default resting position changes. An install
        // whose stored version is below this has its saved x/y cleared
        // once so it adopts the new default (middle of the left edge)
        // instead of a stale dragged spot. Drag-persist re-stamps it.
        private const val KEY_POS_VERSION = "pos_version"
        private const val POS_VERSION = 2

        // Process-local "is the service alive?" flag. Volatile so a
        // method-channel read from the platform thread sees the latest
        // value without acquiring a lock.
        @Volatile
        private var running: Boolean = false

        // Process-local "is the overlay currently suspended for
        // multi-window?" flag. Set by ACTION_SUSPEND, cleared by
        // ACTION_RESUME. While true, regular onStartCommand calls
        // (e.g. from a tap-to-show entry point) won't re-attach the
        // overlay — only ACTION_RESUME can lift the suspension.
        @Volatile
        private var suspended: Boolean = false

        fun isRunning(): Boolean = running

        private fun sharedPrefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }
}
