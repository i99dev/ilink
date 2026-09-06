package com.i99dev.ilink

import android.Manifest
import android.app.ActivityOptions
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.Display
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.util.Log
import com.i99dev.ilink.adb.AdbBootstrap
import com.i99dev.ilink.adb.AdbBootstrapPlugin
import com.i99dev.ilink.adb.AdbSetupPlugin
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.device.DeviceEnv
import com.i99dev.ilink.launcher.LauncherActivityHolder
import com.i99dev.ilink.tools.ToolsBridgePlugin
import com.i99dev.ilink.bubble.BubbleOverlayPlugin
import com.i99dev.ilink.bubble.BubbleOverlayService
import com.i99dev.ilink.connectivity.ConnectivityService
import com.i99dev.ilink.ota.OtaChannel
import com.i99dev.ilink.car.CarChannel
import com.i99dev.ilink.car.EncryptedCarTableSource
import com.i99dev.ilink.car.UnitDispatcher
import com.i99dev.ilink.content.ContentUriBridge
import com.i99dev.ilink.miniapps.EncryptedMiniAppTableSource
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import com.i99dev.ilink.minishortcut.HomeScreenShortcutHandler
import com.i99dev.ilink.network.NetworkInfoChannel
import com.i99dev.ilink.security.IntegrityMonitor
import com.i99dev.ilink.security.NativeSecrets
import com.i99dev.ilink.security.SecureLogger
import com.i99dev.ilink.security.SecurityChannel
import com.i99dev.ilink.voice.PttMediaSession
import com.i99dev.ilink.voice.VoiceChannel
import com.i99dev.ilink.voice.WheelVoiceController
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// Extends AudioServiceActivity (not FlutterActivity) because
// just_audio_background.init() requires the hosting Activity to expose the
// audio_service plugin's MediaBrowserService binding. Without this, init()
// throws PlatformException("The Activity class declared in your
// AndroidManifest.xml is wrong...") during main(), before runApp() — the
// app comes up as a permanent black screen.
class MainActivity : AudioServiceActivity() {
    private var voiceChannel: VoiceChannel? = null
    private var pttSession: PttMediaSession? = null
    private var platformPlugins: PlatformPluginsHandle? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Driver-profile only. BYD Leopard 8 (and most multi-display
        // car infotainment systems) ship with at least two Android
        // user profiles — user 0 (driver) and user 999 (passenger /
        // co-driver). If our APK lands in a non-primary user (via
        // ``adb install`` without ``--user 0``, or a passenger
        // sideloading from their own Telegram profile), TWO dash
        // instances run with the same deviceId-derived MQTT
        // clientId — the broker disconnects each on the other's
        // arrival in a sub-second reconnect storm, presence flaps,
        // and every cmd ACK round-trip is poisoned. We solve the
        // ``adb install`` case via documentation (see memory:
        // car-install-user-0-only); this runtime guard is the
        // defence-in-depth so a sideload onto the wrong user can
        // never cause the same outage.
        //
        // ``Process.myUid() / 100000`` is the user id encoded in the
        // Android UID scheme — user 0 (driver / primary) is uid range
        // 10000-19999, user 999 (passenger) is 99910000-99919999.
        // Dividing by 100000 normalises to the user id directly,
        // which is the SDK-public way to detect "what user am I
        // running as" without touching the @SystemApi UserHandle
        // constants. Any non-zero result terminates immediately —
        // finishAndRemoveTask closes the activity AND removes it
        // from the recents stack so the user doesn't see a tombstone.
        // No toast, no engine init: by the time the user-999
        // instance reaches this line we want it to be invisible.
        val userId = android.os.Process.myUid() / 100000
        // Only enforce the BYD "primary driver == user 0" assumption on real
        // car hardware. AAOS emulators run the primary "Driver" as user 10
        // (the headless system user owns user 0), so without this carve-out
        // the app would self-terminate on every emulator launch. Real head
        // units are never detected as emulators -> production unchanged.
        if (userId != 0 && !DeviceEnv.isEmulator) {
            Log.w(
                "MainActivity",
                "non-primary user (userId=$userId) — terminating to avoid " +
                    "MQTT clientId conflict on a multi-user car HU",
            )
            finishAndRemoveTask()
            return
        }
        requestRuntimePermissionsIfNeeded()
        // Seed DisplayMemory's locale so its tuple keys reflect the
        // system language from boot. Lifecycle: onCreate populates,
        // onConfigurationChanged flushes + repopulates on flip.
        applyLocaleToDisplayMemory()
        // Anchor the process with the always-on "car online" keep-alive
        // so a normal car start (IVI resume-from-standby, no
        // BOOT_COMPLETED) finds the dash + MQTT presence already
        // resident instead of reaped. No-op when the driver disabled it.
        ConnectivityService.startIfEnabled(this)
        // VOICE_COMMAND / ASSIST may have launched us — defer until after
        // the engine configures (VoiceChannel is null right now).
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AdbShellBridge.init(applicationContext)
        // Native LocationManager bridge — bypasses the geolocator
        // package's broken-on-BYD-HU FusedLocationProvider path.
        // Verified: with geolocator alone we appear under
        // ``com.android.location.fused`` in dumpsys but never get
        // fresh emissions; with this bridge we appear directly
        // under ``gps provider`` listeners alongside Waze /
        // Yandex Maps and start receiving real fixes within 1–3 s.
        // EventChannel name matches the Dart-side reader; the
        // bridge holds no state per-stream so registering once at
        // engine bind is enough.
        io.flutter.plugin.common.EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            com.i99dev.ilink.location.LocationBridge.CHANNEL_NAME,
        ).setStreamHandler(
            com.i99dev.ilink.location.LocationBridge(applicationContext),
        )
        // Bring up secure logging first — the integrity monitor and later
        // subsystems want to emit through it from their constructors.
        // Silently no-op if the device is too locked down to provide the
        // key material (fromContext already degrades gracefully).
        runCatching { SecureLogger.init(applicationContext) }
        // Outbox for tamper signals must exist BEFORE IntegrityMonitor
        // starts — its first tick can already enqueue (signer pin check
        // runs on start). Best-effort init; failures are silent.
        runCatching { IntegrityMonitor.init(applicationContext) }
        // Touch NativeSecrets early so the native library load + smoke
        // ping fire on boot rather than on the first integrity tick
        // (60s later). Logs "loaded dash_secrets on <abi>" if OK, falls
        // back silently if the .so is missing for this device's ABI.
        Log.i(TAG, "NativeSecrets available=${NativeSecrets.isAvailable} abi=${NativeSecrets.abi()}")
        SecurityChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger).register()
        // On-device voice (Phase 1b): Vosk grammar recognizer bridge. Inert
        // until a Kaldi model is provisioned (VoskModelStore) and the Dart
        // brain calls applyGrammar/start — no model ⇒ cloud-only, unchanged.
        com.i99dev.ilink.voice.ondevice.OnDeviceVoiceChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).register()
        // Swap the dispatcher's data source to the encrypted CarTable asset
        // if it's shipped + decryptable. Null → UnitDispatcher keeps its
        // empty default and every dispatch fails closed at the gate. The
        // swap logs the version transition ("CarTableSource swapped:
        // empty-v1 -> encrypted-…") so a field report's dispatch log can
        // be traced back to the source that produced it.
        //
        // The trailing Log.i is load-bearing for R8 release builds: it
        // reads sourceVersion() which reads UnitDispatcher.source, and
        // that observable side-effect keeps R8 from eliminating the
        // entire init block as dead code during whole-program analysis.
        runCatching {
            EncryptedCarTableSource.loadOrNull(applicationContext)?.let {
                UnitDispatcher.setSource(it)
            }
        }
        Log.i(TAG, "CarTableSource active: ${UnitDispatcher.sourceVersion()}")
        // Same swap pattern for the mini-apps table. Phase 0+1 ships
        // this loader without yet routing any family handler through
        // it — handlers keep their hardcoded paths until each family's
        // Phase 2 migration PR. So an empty source on a release device
        // means "no migrated families yet," not a regression.
        runCatching {
            EncryptedMiniAppTableSource.loadOrNull(applicationContext)?.let {
                MiniAppDispatcher.setSource(it)
            }
        }
        Log.i(TAG, "MiniAppTableSource active: ${MiniAppDispatcher.sourceVersion()}")
        CarChannel(this, flutterEngine.dartExecutor.binaryMessenger).register()
        // Mini Apps "Add to Home Screen". Stateless — no instance to
        // hold, just a method-channel handler wrapping ShortcutManagerCompat.
        HomeScreenShortcutHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).register()
        // Cellular-generation reader (2G/3G/4G/5G) for the top status
        // bar's network indicator. Stateless — wraps a single
        // TelephonyManager call per Dart-side invocation.
        NetworkInfoChannel(applicationContext).register(
            flutterEngine.dartExecutor.binaryMessenger,
        )
        // ContentResolver bridge for the "Open with ilink" BYO flow.
        // Activated when an ACTION_VIEW intent (file manager / browser
        // share) lands on a `.m3u` content:// URI — the Dart importer
        // reads the bytes through this channel because dart:io File
        // can't open content URIs.
        ContentUriBridge(applicationContext).register(
            flutterEngine.dartExecutor.binaryMessenger,
        )
        voiceChannel = VoiceChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.register() }
        // PTT MediaSession captures steering-wheel media buttons even when
        // the Activity is backgrounded / focus is lost (e.g. user swiped
        // to another app). onKeyDown alone only works while Activity has
        // input focus, which BYD's multi-user split-screen often strips.
        voiceChannel?.let { vc ->
            pttSession = PttMediaSession(applicationContext, vc).also { it.start() }
        }
        // Handle a launch-time voice intent now that the channel is ready.
        voiceChannel?.forwardVoiceIntent(intent)

        // Settings control for the dynamic steering-wheel voice override —
        // reads/writes WheelVoiceController's enable flag (the source of
        // truth the a11y key filter consults).
        com.i99dev.ilink.voice.WheelVoiceChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).register()

        // "Car online" keep-alive toggle — reads/writes ConnectivityService's
        // SharedPreferences enable flag (the source of truth its start path
        // consults) and starts/stops the foreground service immediately.
        com.i99dev.ilink.connectivity.ConnectivityChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).register()

        OtaChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger).register()

        // Onboarding-side hook into the AdbBootstrap state machine.
        // Lets the Dart onboarding screen query whether the cold-launch
        // grant attempt was Skipped (Wireless debugging not yet on)
        // and re-trigger after the user flips it. The retry path
        // shells to loopback ADB so it offloads onto a worker thread.
        AdbBootstrapPlugin(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)
        // Tools + AppActions shell bridge — separate channel so its
        // surface stays narrow and auditable. Routes argv through
        // AdbShellBridge.shell() with single-arg quoting on the
        // platform side.
        ToolsBridgePlugin()
            .register(flutterEngine.dartExecutor.binaryMessenger)

        // Sibling plugin for the contextual "Allow USB debugging"
        // overlay. Streams AdbShellBridge phase transitions to Dart so
        // the in-app card can paint UNDER the system prompt before it
        // fires, explaining the one-time setup. Distinct from
        // AdbBootstrapPlugin (which is the one-shot grant runner).
        AdbSetupPlugin(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)

        // Floating "chat head" bubble. Needs a WeakReference to this
        // Activity so `minimize` can call moveTaskToBack(true) (which
        // is Activity-scoped) without leaking the Activity if Dart
        // holds the channel longer than expected.
        BubbleOverlayPlugin(
            applicationContext,
            java.lang.ref.WeakReference(this),
        ).register(flutterEngine.dartExecutor.binaryMessenger)

        // Floating per-app shortcut buttons (independent draggable overlays,
        // one per pinned package; tap launches that app directly).
        com.i99dev.ilink.shortcut.AppShortcutOverlayPlugin(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)

        // Sweep any stuck overlay-blocker leftover from a previous
        // session (BYD's cluster-projection ResolverActivity, etc.).
        // While such a window is alive the bubble paints with alpha=0
        // even though the appop is granted. Off the main thread —
        // shells dumpsys via loopback ADB, blocks ~2 s. Best-effort:
        // if the daemon isn't ready yet, OverlayHealthGuard returns 0
        // and the next bubble-show retries the sweep on its own.
        Thread({
            try {
                val cleared = com.i99dev.ilink.bubble.OverlayHealthGuard.sweep()
                if (cleared > 0) {
                    Log.i(TAG, "overlay health: cleared $cleared stuck blocker(s) at startup")
                }
            } catch (t: Throwable) {
                Log.w(TAG, "startup overlay sweep threw: ${t.message}")
            }
        }, "OverlayHealthGuard-startup").apply { isDaemon = true }.start()

        // Native-capability + device plugins. Each plugin owns its
        // own MethodChannel + (optionally) EventChannel; the Dart
        // side reads through a thin `*NativeBridge` so business
        // logic stays platform-agnostic. See
        // `lib/features/mini_apps/bridge/`. PlatformPlugins.installAll
        // is the one-call site for adding/removing native-capability
        // plugins so MainActivity doesn't grow a nullable field per
        // plugin.
        platformPlugins = PlatformPlugins.installAll(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )

        // Cold-start AdbBootstrap is intentionally lazy on the loopback-
        // ADB connection. Why: BYD Leopard 8's adbd doesn't persist
        // /data/misc/adb/adb_keys across package replaces — every
        // pm install -r kicks the prior key authorization, so any
        // eager loopback connection at boot fires the "Allow USB
        // debugging?" prompt EVERY install regardless of whether the
        // user previously ticked "Always allow".
        //
        // [AdbBootstrap.runIfNeeded] fast-paths to AlreadyApplied
        // without opening any ADB connection when persistedVersion
        // already matches BOOTSTRAP_VERSION (the steady-state case).
        // Only a version bump triggers an actual shell sequence —
        // and that prompt is unavoidable on this ROM.
        //
        // The daemon warmup that used to live here was the OTHER
        // source of the boot-time prompt: ensureDaemon would respawn
        // DashDaemon over loopback ADB whenever the prior daemon's
        // CLASSPATH pointed at a stale APK path (always true after
        // a reinstall). Moving that to lazy-on-first-use means the
        // prompt only fires when the user actually exercises a
        // shell-dependent feature (cluster mini-app launch, cursor
        // overlay, app-launch on FSE/Driver display) — so a user
        // who never opens those features sees zero prompts after
        // the first install.
        //
        // First-use cost: ~1-3s daemon spawn on the first feature
        // tap. Subsequent taps in the same session reuse the daemon
        // and run at fastCall* latency (~5-10ms).
        Thread({
            try {
                val r = AdbBootstrap.runIfNeeded(applicationContext)
                Log.i(TAG, "AdbBootstrap result: $r")
            } catch (t: Throwable) {
                Log.w(TAG, "AdbBootstrap threw: ${t.javaClass.simpleName}: ${t.message}")
            }
            // Eager daemon spawn — independent of bootstrap version
            // short-circuit. After `install -r` or `am force-stop`,
            // the daemon child process is gone but persistedVersion
            // still matches, so runIfNeeded returns AlreadyApplied
            // without touching the daemon. Without this call, the
            // dashboard renders empty until some unrelated MethodChannel
            // path happens to invoke ensureDaemon (~30-60s window).
            try {
                val up = com.i99dev.ilink.adb.AdbShellBridge.ensureDaemon()
                Log.i(TAG, "eager ensureDaemon: $up")
            } catch (t: Throwable) {
                Log.w(TAG, "eager ensureDaemon threw: ${t.javaClass.simpleName}: ${t.message}")
            }
        }, "adb-bootstrap").apply { isDaemon = true }.start()

        // Resolve the steering-wheel voice key for THIS car from its
        // keylayouts (no hardcoded scancode), on its OWN thread — NOT behind
        // the adb-bootstrap thread above, because ensureDaemon can block on a
        // cold/wedged ADB auth and the scancode comes from world-readable
        // keylayout files (direct I/O, no bridge). Once resolved,
        // dispatchKeyEvent + the a11y key filter intercept the button across
        // Di5.0 / Di5.1 and fire our voice instead of BYD's autovoice. Inert
        // if the ROM declares no voice key.
        Thread({
            try {
                WheelVoiceController.warmUp(applicationContext)
            } catch (t: Throwable) {
                Log.w(TAG, "wheel-voice warmUp threw: ${t.javaClass.simpleName}: ${t.message}")
            }
        }, "wheel-voice").apply { isDaemon = true }.start()
    }

    override fun onResume() {
        super.onResume()
        // Hand the launcher plugins a foreground-Activity reference so
        // role-grant + settings intents land on the same display the
        // user is on (multi-display HUs would otherwise pick an
        // arbitrary default and the user never sees the dialog).
        LauncherActivityHolder.setActivity(this)
        // Auto-dismiss the floating "chat head" whenever the user
        // returns to the app via any path (bubble tap, recents,
        // launcher, voice intent). Idempotent — stopService no-ops if
        // the service isn't running.
        stopService(Intent(this, BubbleOverlayService::class.java))
        // Keep ilink on the IVI. See [correctToIviIfNeeded].
        correctToIviIfNeeded()
        // Ensure our accessibility services are ENABLED + bound on every open, no
        // Settings/diagnostics trip: enable them if missing (we hold
        // WRITE_SECURE_SETTINGS on the car), and re-toggle a crashed binding (after
        // an OOM/kill the framework leaves them listed-but-unbound and won't rebind,
        // starving the nav-HUD a11y pipeline). No-op without the permission.
        runCatching { com.i99dev.ilink.input.A11yHealer.ensureEnabled(applicationContext) }
    }

    /**
     * Display-affinity guard: snap MainActivity back to the IVI if the
     * BYD ROM placed it on a secondary screen.
     *
     * The bug this fixes: we declare `resizeableActivity="true"` +
     * `launchMode="singleTask"`, and BYD's multi-display vendor policy
     * (`adjustDisplayIdForMultiDisplay` / `PreferredTaskDisplayArea` —
     * see [com.i99dev.ilink.launcher.LauncherBootstrapPlugin]) is free
     * to route a launch onto the cluster / fission / passenger display
     * instead of the IVI. Because we're `singleTask`, once the one task
     * lands on a secondary display a relaunch just brings it forward
     * THERE (the task is reused wherever it lives) — so the misplacement
     * sticks. Nothing else pins us to the IVI. Symptom: "ilink
     * sometimes reopens on the wrong screen."
     *
     * Fix: when we resume on anything other than the IVI, re-launch
     * ourselves pinned to it via `setLaunchDisplayId`. The IVI is the
     * default display ([Display.DEFAULT_DISPLAY] = 0 — `"ivi"`, the
     * INTERNAL panel, on every BYD unit we've inspected).
     *
     * Loop safety: the BYD router can in principle override even an
     * explicit `setLaunchDisplayId`, which would spin us. So corrections
     * are budgeted ([MAX_IVI_CORRECTIONS]) within a short window
     * ([IVI_CORRECTION_WINDOW_MS]); past the budget we give up and stay
     * put rather than thrash. The budget resets once we observe
     * ourselves back on the IVI (or after the window elapses), so a
     * fresh misplacement later gets a fresh budget. State is process-
     * static (companion) so it survives the relaunch's new instance.
     *
     * Skipped while finishing / changing config / in multi-window — in
     * a docked split the activity may legitimately live on another area
     * and we must not fight it.
     */
    private fun correctToIviIfNeeded() {
        if (isFinishing || isChangingConfigurations || isInMultiWindowMode) return
        val current = currentDisplayId()
        if (current == Display.DEFAULT_DISPLAY) {
            // We're home — clear the budget so a future episode starts fresh.
            iviCorrectionCount = 0
            return
        }
        val now = System.currentTimeMillis()
        if (now - iviCorrectionWindowStartMs > IVI_CORRECTION_WINDOW_MS) {
            iviCorrectionWindowStartMs = now
            iviCorrectionCount = 0
        }
        if (iviCorrectionCount >= MAX_IVI_CORRECTIONS) {
            Log.w(
                TAG,
                "MainActivity stuck on display $current (want IVI=" +
                    "${Display.DEFAULT_DISPLAY}); re-pin budget exhausted this window",
            )
            return
        }
        iviCorrectionCount++
        Log.i(
            TAG,
            "MainActivity resumed on display $current (not IVI) — re-pinning to " +
                "${Display.DEFAULT_DISPLAY} (attempt $iviCorrectionCount/$MAX_IVI_CORRECTIONS)",
        )
        try {
            val opts = ActivityOptions.makeBasic()
                .setLaunchDisplayId(Display.DEFAULT_DISPLAY)
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                opts.toBundle(),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "IVI re-pin failed: ${t.message}")
        }
    }

    /** The display this Activity is currently on. `Activity.getDisplay()`
     *  is API 30+, so fall back to the (deprecated) default-display path
     *  on minSdk 24..29. On any failure returns [Display.DEFAULT_DISPLAY]
     *  so the IVI guard treats us as already-home (no spurious re-pin). */
    @Suppress("DEPRECATION")
    private fun currentDisplayId(): Int =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            display?.displayId ?: Display.DEFAULT_DISPLAY
        } else {
            windowManager?.defaultDisplay?.displayId ?: Display.DEFAULT_DISPLAY
        }

    override fun onPause() {
        LauncherActivityHolder.clearActivity(this)
        super.onPause()
    }

    /**
     * The user intentionally left the app — HOME, recents, the BYD
     * launcher, an external app, or a voice intent. Spawn the floating
     * bubble so there's ALWAYS a way back, not only when the in-app
     * minimize button was tapped (the previous sole trigger — every
     * other background path left no bubble at all).
     *
     * `onUserLeaveHint` fires only on user-initiated departure, never
     * on a config change or a transient activity over us, so we don't
     * flash a bubble on rotation / permission dialogs. `onResume`
     * tears it back down on return.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        startBubbleForBackground()
    }

    /**
     * Safety net for departure paths that don't deliver
     * `onUserLeaveHint` (some BYD launcher / programmatic app
     * switches). Guarded so an actual app close (`isFinishing`) or a
     * config change never spawns a bubble. Multi-window is owned by
     * `onMultiWindowModeChanged`'s SUSPEND/RESUME — stay out of its
     * way here so we don't fight the SurfaceFlinger-safety dance.
     */
    override fun onStop() {
        if (!isFinishing && !isChangingConfigurations && !isInMultiWindowMode) {
            startBubbleForBackground()
        }
        super.onStop()
    }

    /**
     * Start the overlay foreground service. No x/y is passed: the
     * service restores the user's last dragged position from prefs,
     * so the seed only matters on the first-ever run. Idempotent —
     * the service no-ops a re-start when the bubble is already
     * attached or legitimately suspended for multi-window.
     */
    private fun startBubbleForBackground() {
        // User opted out of the floating button (Settings → Appearance). Honour it
        // here so backgrounding never spawns the bubble.
        if (!BubbleOverlayService.isEnabled(this)) return
        try {
            ContextCompat.startForegroundService(
                this,
                Intent(this, BubbleOverlayService::class.java),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "bubble background-start failed: ${t.message}")
        }
    }

    override fun onDestroy() {
        pttSession?.stop()
        pttSession = null
        platformPlugins?.disposeAll()
        platformPlugins = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // CRITICAL: replace the activity's "current intent" so plugins
        // that read it (Flutter's app_links, MediaButton receivers, …)
        // see the new URI instead of the original launch intent.
        // Without this, ACTION_VIEW deep-links delivered after launch
        // (the "tap a .m3u while ilink is already running" path) are
        // silently dropped — the activity foregrounds but no handler
        // ever fires. See:
        //   https://developer.android.com/reference/android/app/Activity#onNewIntent(android.content.Intent)
        setIntent(intent)
        // Re-entry via singleTask: voice key or intent filter delivered a
        // new intent to the existing activity. Forward to Dart.
        voiceChannel?.forwardVoiceIntent(intent)
    }

    // dispatchKeyEvent — not onKeyDown — because gamepad/joystick
    // keycodes (e.g. BUTTON_THUMBL, which is how this BYD head unit
    // delivers its steering-wheel voice button) are routed differently
    // and don't always reach onKeyDown. Catching at dispatch gets
    // everything.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Dynamic, ROM-declared wheel-voice key first: WheelVoiceController
        // matches on the scancode discovered from this car's keylayouts
        // (AUTO_MEDIA_VOICE etc.) rather than a hardcoded keycode, fires our
        // voice, and consumes the press. Returns false when nothing's
        // resolved yet or the key doesn't match, so the legacy fallbacks
        // below still cover keycode-routed wheels and the pre-resolve window.
        if (WheelVoiceController.handleKeyEvent(event, this)) return true
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            Log.i(TAG, "dispatchKeyEvent keyCode=${event.keyCode} scanCode=${event.scanCode} (${KeyEvent.keyCodeToString(event.keyCode)})")
            if (isPttKey(event.keyCode)) {
                voiceChannel?.pushHardwareKey()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun isPttKey(keyCode: Int): Boolean = when (keyCode) {
        // "«" prev-track button — BYD wheel sends this.
        KeyEvent.KEYCODE_MEDIA_PREVIOUS,
        // Some BYD wheels route the voice button as a gamepad thumb
        // button via the CAN→input bridge (BTN_THUMB2 in the kernel).
        KeyEvent.KEYCODE_BUTTON_THUMBL -> true
        else -> false
    }

    /**
     * Flush the [DisplayMemory] tuple cache when the system locale
     * changes — the cache keys include locale because Display.name
     * can be locale-dependent (Chinese `"仪表"` vs English
     * `"Dashboard"` for the same physical panel). After a flip we
     * want fresh observations, not stale Chinese-keyed entries.
     *
     * Called from [onCreate] (initial population) and
     * [onConfigurationChanged] (live flip while the app is open).
     */
    private fun applyLocaleToDisplayMemory() {
        val lang = resources.configuration.locales.get(0)?.toLanguageTag() ?: ""
        if (lang != com.i99dev.ilink.display.DisplayMemory.lang()) {
            com.i99dev.ilink.display.DisplayMemory.flush()
            com.i99dev.ilink.display.DisplayMemory.setLang(lang)
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // The system runs onConfigurationChanged whenever the user
        // flips device language (or any other declared `configChanges`
        // from the manifest). We don't gate on a CONFIG_LOCALE diff
        // explicitly because applyLocaleToDisplayMemory short-circuits
        // when the language tag is unchanged — cheap and idempotent.
        applyLocaleToDisplayMemory()
    }

    /**
     * Multi-window / split-screen lifecycle hook. BYD's customized WMS
     * has a known bug path when re-parenting our activity into a
     * docked stack while a TYPE_APPLICATION_OVERLAY window owned by
     * our process is still anchored to the full default display —
     * SurfaceFlinger ends up with an inconsistent surface graph and
     * either glitches (best case) or panics system_server which
     * reboots the head unit (worst case). We can't tell ahead of
     * time which way the dice fall on a given dock attempt.
     *
     * Mitigation: when entering multi-window mode, drop the bubble
     * overlay's WindowManager view but keep its foreground service
     * alive. On exit, re-attach it at the persisted position. The
     * service stays in foreground throughout, so the OS doesn't
     * reclaim its FGS slot during the transition.
     *
     * onMultiWindowModeChanged also fires on API 26+ when the user
     * resizes the docked partition — re-issuing SUSPEND while already
     * suspended is a no-op inside the service, so the duplicate fire
     * is harmless. Same for RESUME.
     */
    override fun onMultiWindowModeChanged(
        isInMultiWindowMode: Boolean,
        newConfig: android.content.res.Configuration?,
    ) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        if (!BubbleOverlayService.isRunning()) return
        val intent = Intent(this, BubbleOverlayService::class.java).apply {
            action = if (isInMultiWindowMode) {
                BubbleOverlayService.ACTION_SUSPEND
            } else {
                BubbleOverlayService.ACTION_RESUME
            }
        }
        try {
            startService(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "bubble suspend/resume dispatch failed: ${t.message}")
        }
    }

    private fun requestRuntimePermissionsIfNeeded() {
        val needed = listOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.POST_NOTIFICATIONS,
        ).filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (needed.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), REQ_RUNTIME)
        }
    }

    companion object {
        private const val REQ_RUNTIME = 42
        private const val TAG = "MainActivity"

        // ── IVI display-affinity guard (see [correctToIviIfNeeded]) ──
        /** Max self-relaunches to the IVI inside one window before we
         *  give up (loop backstop against a ROM that overrides
         *  setLaunchDisplayId). */
        private const val MAX_IVI_CORRECTIONS = 3
        /** Re-pin budget window. After this elapses a fresh misplacement
         *  gets a fresh budget. */
        private const val IVI_CORRECTION_WINDOW_MS = 10_000L
        /** Process-static so the budget survives the relaunch's new
         *  Activity instance (singleTask may recreate us). */
        @Volatile private var iviCorrectionCount = 0
        @Volatile private var iviCorrectionWindowStartMs = 0L
    }
}
