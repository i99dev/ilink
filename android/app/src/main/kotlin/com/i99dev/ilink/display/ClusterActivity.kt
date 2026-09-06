package com.i99dev.ilink.display

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Presentation
import android.content.Intent
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.view.Display
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import com.i99dev.ilink.pkg.AmShellRunner
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Activity that hosts a sandboxed [WebView] for a mini-app's bundle.
 * Launched onto a non-default display via loopback ADB:
 *
 *   am start-activity -S --display N \
 *     -n com.i99dev.ilink/.display.ClusterActivity \
 *     --es bundleUri 'file:///data/data/.../index.html' \
 *     --es route '/cluster.html' \
 *     --es surfaceId 'sfc_xxx'
 *
 * Why this Activity exists, given that [SurfacePlatformPlugin] already
 * has both `Presentation` and `TYPE_APPLICATION_OVERLAY` paths: on the
 * Leopard 8's XDJA-virtualized cluster displays, the XDJA composer
 * filters frames by the calling-app uid. Frames produced by `Presentation`
 * or overlay windows owned by our uid (10181 or whatever the runtime
 * assigns) are silently dropped; non-system apps can't reach the
 * cluster MCU through those paths.
 *
 * Activities launched via `am start-activity --display N` are spawned by
 * `ActivityManagerService` (system uid 1000) on behalf of the shell uid
 * (2000) with the activity instance running under our uid. XDJA accepts
 * frames from this pathway because the launch was system-mediated. This
 * is the same pattern `com.byd.cluster` and `com.example.amapservice` use
 * (per `.l8/dlink-unit/driver/projection.md`) and the only path i99dev
 * found that works on Leopard 8 (per their dex strings —
 * `am start-activity -S --display`).
 *
 * Self-registration: each instance registers itself in a static map keyed
 * by `surfaceId` so [SurfacePlatformPlugin]'s `surface.destroy` can
 * locate and `finish()` the right Activity from the IVI process.
 */
class ClusterActivity : Activity() {

    companion object {
        private const val TAG = "ClusterActivity"

        const val EXTRA_BUNDLE_URI = "bundleUri"
        const val EXTRA_ROUTE = "route"
        const val EXTRA_SURFACE_ID = "surfaceId"
        const val EXTRA_APP_ID = "appId"

        // ── Foreign-app projection mode (the reference cluster mechanism) ──
        // When EXTRA_PROJECT_PKG is set, this slot-host activity hosts a
        // SurfaceView backed by a VirtualDisplay WE create, then am-starts
        // the named package onto that VD. The foreign app renders to our
        // own virtual display (its own display group) — never to a BYD
        // XDJA OWN_CONTENT_ONLY fission display in the IVI's group-0 stack
        // — so it cannot reshuffle group 0 or latch FissionGenerayService
        // the way `am stack move-task <foreignTask> 4` does (the L7 hang).
        // Optional EXTRA_PROJECT_W/H override the VD size (default = this
        // cluster display's metrics).
        const val EXTRA_PROJECT_PKG = "ilink.project.pkg"
        const val EXTRA_PROJECT_W = "ilink.project.w"
        const val EXTRA_PROJECT_H = "ilink.project.h"

        // ── Own-content projection mode (iLINK UI on the cluster) ──
        // When EXTRA_PROJECT_BUNDLE is set, the same VirtualDisplay
        // mechanism hosts OUR OWN WebView (a mini-app bundle) on the VD
        // via a Presentation — the cluster shows an iLINK dashboard,
        // not a foreign app. This is the L7-safe way to put our content
        // on the cluster on trims where a direct am-start of this Activity
        // onto the cluster's own display is rejected by the XDJA composer:
        // the WebView renders into a Presentation on a VirtualDisplay WE
        // own, whose backing Surface is this Activity's SurfaceView (which
        // DOES paint on the cluster). It is a passive display surface — no
        // touchpad input is forwarded to it (unlike the foreign-app cast,
        // our own UI needs no synthetic touch). Reuses EXTRA_ROUTE /
        // EXTRA_APP_ID / EXTRA_PROJECT_W/H.
        const val EXTRA_PROJECT_BUNDLE = "ilink.project.bundle"

        // Calibration-tour mode extras. When EXTRA_TOUR_MODE == "1" we
        // skip the WebView / amap-watchdog path entirely and render a
        // full-screen marker tile so the user can identify which
        // physical screen this Activity landed on. Lets us reuse one
        // signed component for two purposes (cluster surface host +
        // tour marker) instead of shipping a second activity that
        // would need its own manifest entry + intent filter.
        const val EXTRA_TOUR_MODE = "ilink.tour"
        const val EXTRA_TOUR_DISPLAY_ID = "ilink.tour.displayId"
        const val EXTRA_TOUR_COLOR_ARGB = "ilink.tour.colorArgb"
        const val EXTRA_TOUR_LABEL = "ilink.tour.label"

        // Blank mode: when EXTRA_TOUR_BLANK == "1" the tour path
        // renders ONLY the opaque colour fill — no "DISPLAY n"
        // marker text. Used by the Di5.1 doMove path to repaint a
        // projected secondary display (cluster / FSE) that
        // `am display move-stack` just vacated, so SurfaceFlinger
        // doesn't leave the previous app's last frame frozen there.
        const val EXTRA_TOUR_BLANK = "ilink.tour.blank"

        /** Action filter — must match what `am start-activity -a <ACTION>`
         *  uses. We use an explicit `-n component` form too, but keeping
         *  the action makes manual `adb shell` testing easier. */
        const val ACTION_OPEN = "com.i99dev.ilink.action.OPEN_CLUSTER_SURFACE"

        /** Per-process registry of live cluster activities. Read +
         *  written from the main thread only — Activity lifecycle
         *  callbacks already serialize on it. */
        private val live = mutableMapOf<String, ClusterActivity>()

        /** Live tour-marker activities. Separate from [live] because
         *  tour markers don't have a surfaceId (they aren't a mini-app
         *  surface) — we just need a flat set so the IVI overlay can
         *  finish() every active marker when the calibration tour ends
         *  or is cancelled. Without this, the last-shown marker stays
         *  pinned on the cluster screen until the user manually
         *  navigates away. */
        private val liveTours = mutableSetOf<ClusterActivity>()

        /** The active foreign-app projection surface, if any. Tracked so
         *  the DISPLAYS card's "return to Head Unit" action can stop the
         *  cast (the projected app runs on our VirtualDisplay, not on the
         *  cluster's Android display id, so the host's `topOnDisplay`
         *  can't find it). */
        @Volatile
        private var liveProjection: ClusterActivity? = null

        /** Finish the active projection cluster surface. Returns the
         *  package that was being projected (so the caller can relaunch
         *  it on the IVI for "return to Head Unit"), or null if nothing is
         *  projecting. The finish() triggers onDestroy → releaseProjection
         *  (VD released + projected app force-stopped). */
        fun stopProjection(): String? {
            val a = liveProjection ?: return null
            val pkg = a.projectedPkg
            a.runOnUiThread {
                if (!a.isFinishing && !a.isDestroyed) a.finish()
            }
            return pkg
        }

        /** Active projection as (projectedPkg, vdDisplayId, hostDisplayId),
         *  or null. `hostDisplayId` is the cluster Android display this
         *  ClusterActivity is hosted on (the DISPLAYS-card id); the cast
         *  app actually runs on `vdDisplayId` (our VirtualDisplay).
         *  handleRunning uses this to re-attribute the cast app's task to
         *  the cluster card, so the card shows it as a running chip. */
        fun activeProjection(): Triple<String, Int, Int>? {
            val a = liveProjection ?: return null
            val pkg = a.projectedPkg ?: return null
            val vd = a.virtualDisplay?.display?.displayId ?: return null
            val host = try {
                @Suppress("DEPRECATION")
                a.windowManager.defaultDisplay.displayId
            } catch (t: Throwable) {
                return null
            }
            return Triple(pkg, vd, host)
        }

        /** Look up a live activity by its surface id. Returns null if
         *  the activity has already finished or never started. */
        fun find(surfaceId: String): ClusterActivity? = live[surfaceId]

        /** Snapshot of currently-live cluster surfaces (debug + audit). */
        fun liveSurfaceIds(): Set<String> = live.keys.toSet()

        /** Finish every live tour-marker activity. Called from the
         *  IVI overlay when the calibration flow ends (commit / cancel
         *  / advance into a non-marker phase). Posts each finish() to
         *  the activity's own main thread — cluster-display activities
         *  live in their own process slice and finish() must run on
         *  their UI thread. Returns the number of activities that
         *  were asked to finish so callers can log it. */
        fun finishAllTours(): Int {
            // Snapshot before iterating — finish() removes from the set
            // via onDestroy, mutating during iteration would throw.
            val snapshot = liveTours.toList()
            for (a in snapshot) {
                a.runOnUiThread {
                    if (!a.isFinishing && !a.isDestroyed) {
                        a.finish()
                    }
                }
            }
            return snapshot.size
        }
    }

    private var webView: WebView? = null
    private var surfaceId: String? = null
    private var amapWatchdog: ScheduledExecutorService? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var projectedPkg: String? = null
    /** Live Presentation for own-content projection (EXTRA_PROJECT_BUNDLE).
     *  Hosts our WebView on [virtualDisplay]; dismissed in [releaseProjection]. */
    private var contentPresentation: Presentation? = null

    /** Re-route inside the active WebView. Called by
     *  `SurfacePlatformPlugin.handleNavigate` for am-start surfaces.
     *  Caller is responsible for posting to the UI thread. */
    fun loadUrlOnWebView(url: String) {
        webView?.let { SecondarySurfaceWebView.navigate(it, url) }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ── Z-order hoist ────────────────────────────────────────
        // The XDJA composer DOES accept frames from an `am start`-
        // launched Activity (verified 2026-05-02); the symptom that
        // looked like "no pixels on the cluster" was actually our
        // WebView painting BEHIND `com.example.amapservice`'s ADAS
        // map layer on the same display's task stack. Three flips
        // hoist us above amap:
        //
        //   1. `setShowWhenLocked` + FLAG_SHOW_WHEN_LOCKED — keeps
        //      the activity visible across z-order resets the cluster
        //      MCU triggers when amap re-renders.
        //   2. FLAG_KEEP_SCREEN_ON + FLAG_FULLSCREEN — denies the
        //      system any reason to demote our window.
        //   3. WebView.setZOrderOnTop — the WebView's underlying
        //      SurfaceView climbs above sibling SurfaceViews inside
        //      our window. Without this, the WebView paints below
        //      its own decor on some Chromium builds.
        //
        // The matching manifest entry sets launchMode="singleInstance"
        // so each cluster surface lives in its own task and amap can't
        // ever push us off the stack.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        )

        // Tour-mode short-circuit. No WebView, no surface registration,
        // no amap watchdog — just a full-screen tile the user can see
        // and identify. Reuses the z-order hoist above so the marker
        // actually paints on the cluster (same XDJA composer
        // requirement as the WebView path).
        if (intent?.getStringExtra(EXTRA_TOUR_MODE) == "1") {
            liveTours.add(this)
            renderTourMarker()
            return
        }

        // Foreign-app projection short-circuit — no WebView, no surface
        // registration, no amap watchdog. Hosts a SurfaceView + VD and
        // launches the target package onto it. See [startAppProjection].
        val projectPkg = intent?.getStringExtra(EXTRA_PROJECT_PKG)
        if (!projectPkg.isNullOrEmpty()) {
            startAppProjection(projectPkg)
            return
        }

        // Own-content projection short-circuit — host OUR WebView on a
        // VirtualDisplay via a Presentation (iLINK UI on the cluster). See
        // [startContentProjection] + EXTRA_PROJECT_BUNDLE.
        val projectBundle = intent?.getStringExtra(EXTRA_PROJECT_BUNDLE)
        if (!projectBundle.isNullOrEmpty()) {
            startContentProjection(
                projectBundle,
                intent?.getStringExtra(EXTRA_ROUTE) ?: "/",
                intent?.getStringExtra(EXTRA_APP_ID).orEmpty(),
            )
            return
        }

        val bundleUri = intent?.getStringExtra(EXTRA_BUNDLE_URI)
        val route = intent?.getStringExtra(EXTRA_ROUTE) ?: "/"
        surfaceId = intent?.getStringExtra(EXTRA_SURFACE_ID)
        val appId = intent?.getStringExtra(EXTRA_APP_ID).orEmpty()

        if (bundleUri.isNullOrEmpty()) {
            Log.e(TAG, "missing bundleUri extra — finishing")
            finish()
            return
        }

        Log.i(
            TAG,
            "onCreate displayId=${windowManager.defaultDisplay.displayId} " +
                "surfaceId=$surfaceId appId=$appId route=$route",
        )

        val wv = try {
            SecondarySurfaceWebView.build(this, appId, bundleUri, route, TAG).apply {
                setLayerType(android.view.View.LAYER_TYPE_HARDWARE, null)
            }
        } catch (_: IllegalArgumentException) {
            Log.w(TAG, "Invalid secondary surface bundle or route")
            finish()
            return
        }
        setContentView(wv)
        webView = wv

        surfaceId?.let { live[it] = this }

        // amap watchdog — only on the slot amap actually fights for.
        //
        // Empirically (verified 2026-05-02 on Leopard 8): amap claims
        // id=4 (`shared_fission_bg_XDJAScreenProjection_0`) for its
        // MAP_VIEW projection and aggressively reclaims it. id=5
        // (`_1`) is BYD's secondary overlay slot — amap rarely uses
        // it, so our content holds without periodic eviction.
        // id=3 is the background layer; amap doesn't render there.
        //
        // Killing amap every 2s is genuinely disruptive (resets nav
        // state, ADAS visualizations); only do it on the one display
        // where it's actually needed.
        if (isAmapPrimarySlot()) {
            startAmapWatchdog()
        }
    }

    /** Is THIS activity hosted on amap's primary MAP_VIEW slot?
     *  Only that slot needs the periodic eviction watchdog — the
     *  marker substring lives in the encrypted mini-app table so the
     *  BYD slot name stays out of classes.dex. */
    private fun isAmapPrimarySlot(): Boolean {
        val displayName = windowManager.defaultDisplay.name.orEmpty()
        return displayName.contains(
            MiniAppShellCommands.amapSlotMarker(),
            ignoreCase = true,
        )
    }

    /**
     * Periodic amap eviction. Started in onCreate when this activity
     * is on a cluster display, stopped in onDestroy. Runs every 2s
     * so amap doesn't get a chance to repaint over us between cycles.
     *
     * Skipped if AdbShellBridge isn't connected — without loopback
     * ADB the force-stop call would no-op anyway, no point burning
     * a thread on it.
     *
     * Side effect: every kill resets amap's nav HUD state. Acceptable
     * for the dev / parked-car use case; not safe to leave running
     * mid-trip. The activity self-bounds the loop to its own
     * lifetime — closing the mini-app stops the kills.
     */
    private fun startAmapWatchdog() {
        val exec = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "amap-watchdog").apply { isDaemon = true }
        }
        amapWatchdog = exec
        exec.scheduleAtFixedRate({
            try {
                AdbShellBridge.shell(
                    MiniAppShellCommands.amForceStopAmap(),
                    2_000,
                )
            } catch (t: Throwable) {
                Log.w(TAG, "watchdog force-stop threw: ${t.message}")
            }
        }, 2L, 2L, TimeUnit.SECONDS)
        Log.i(TAG, "amap watchdog started (every 2s)")
    }

    private fun stopAmapWatchdog() {
        amapWatchdog?.shutdownNow()
        amapWatchdog = null
    }

    /**
     * Foreign-app cluster projection — the reference mechanism, adapted to
     * ilink's proven slot-host activity. Hosts a full-screen
     * [SurfaceView]; once its Surface is ready, creates a VirtualDisplay
     * backed by that Surface and launches [pkg] onto the VD via
     * `am start --display <vdId>` (system-mediated loopback ADB, the same
     * path XDJA accepts for our own activities). The app renders to OUR
     * display; its frames are composited into this activity's window,
     * which occupies the cluster projection slot.
     *
     * Safety contract: the foreign app runs on a VirtualDisplay WE create
     * (its own display group), never on a BYD XDJA OWN_CONTENT_ONLY
     * fission display in the IVI's group-0 stack — so it cannot reshuffle
     * group 0 or latch FissionGenerayService the way `am stack move-task`
     * does. This Activity is singleInstance + taskAffinity="" so finishing
     * it never ripples to the IVI's MainActivity.
     */
    private fun startAppProjection(pkg: String) {
        projectedPkg = pkg
        liveProjection = this
        // Log.w (not Log.i) so these survive the R8-stripped release build
        // — this is an experimental high-value path worth field-visible logs.
        Log.w(TAG, "projection start pkg=$pkg onDisplay=${windowManager.defaultDisplay.displayId}")
        val sv = SurfaceView(this)
        setContentView(sv)
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            private var launched = false
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (launched) return
                launched = true
                Log.w(TAG, "projection surfaceCreated — building VD")
                val m = resources.displayMetrics
                val w = (intent?.getIntExtra(EXTRA_PROJECT_W, 0) ?: 0)
                    .takeIf { it > 0 } ?: m.widthPixels
                val h = (intent?.getIntExtra(EXTRA_PROJECT_H, 0) ?: 0)
                    .takeIf { it > 0 } ?: m.heightPixels
                projectOnto(holder.surface, w, h, m.densityDpi, pkg)
            }

            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })
    }

    /**
     * Re-cast onto an already-open cluster surface. ClusterActivity is
     * singleInstance, so a second `pkg.projectCluster` for a different app
     * is delivered HERE (onNewIntent), not onCreate — without this, the
     * re-cast silently no-ops (the "second drag does nothing" symptom).
     * Tear down the current VD + projected app and project the new one.
     */
    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        val projectPkg = intent?.getStringExtra(EXTRA_PROJECT_PKG)
        if (!projectPkg.isNullOrEmpty()) {
            setIntent(intent)
            Log.w(TAG, "projection re-cast → $projectPkg")
            releaseProjection()
            startAppProjection(projectPkg)
        }
    }

    /** Release the projection VD + stop the projected app. Shared by
     *  [onNewIntent] (re-cast) and [onDestroy] (teardown). */
    private fun releaseProjection() {
        if (liveProjection === this) liveProjection = null
        // Dismiss the own-content Presentation BEFORE releasing the VD it lives
        // on (its window is on the VD's display).
        contentPresentation?.let {
            try {
                it.dismiss()
            } catch (t: Throwable) {
                Log.w(TAG, "contentPresentation.dismiss threw: ${t.message}")
            }
        }
        contentPresentation = null
        virtualDisplay?.let {
            try {
                it.release()
            } catch (t: Throwable) {
                Log.w(TAG, "virtualDisplay.release threw: ${t.message}")
            }
        }
        virtualDisplay = null
        projectedPkg?.let { pkg ->
            Thread({
                try {
                    AdbShellBridge.shell("am force-stop $pkg", 2_000)
                } catch (t: Throwable) {
                    Log.w(TAG, "project force-stop threw: ${t.message}")
                }
            }, "cluster-project-stop").apply { isDaemon = true }.start()
        }
        projectedPkg = null
    }

    private fun projectOnto(surface: Surface, w: Int, h: Int, dpi: Int, pkg: String) {
        val dm = getSystemService(DISPLAY_SERVICE) as DisplayManager
        // PRESENTATION only — a PRIVATE virtual display. We must NOT set
        // VIRTUAL_DISPLAY_FLAG_PUBLIC: that needs CAPTURE_VIDEO_OUTPUT
        // (signature perm we don't hold — and the reference doesn't declare it
        // either, confirming the cast uses a private VD). The foreign app
        // is placed onto this VD by the system-mediated `am start
        // --display` (shell uid), which carries the launch privilege; the
        // app's frames render into OUR backing surface. NOT
        // OWN_CONTENT_ONLY — we explicitly want foreign content here.
        val flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
        val vd = try {
            dm.createVirtualDisplay("ilink_cluster_vd", w, h, dpi, surface, flags)
        } catch (t: Throwable) {
            Log.e(TAG, "createVirtualDisplay failed: ${t.message}", t)
            null
        }
        virtualDisplay = vd
        val vdId = vd?.display?.displayId
        if (vdId == null) {
            Log.e(TAG, "no virtual display id — projection aborted for $pkg")
            return
        }
        val component = packageManager.getLaunchIntentForPackage(pkg)
            ?.component?.flattenToShortString()
        Log.w(TAG, "projecting pkg=$pkg onto vdId=$vdId (${w}x$h dpi=$dpi) comp=$component")
        // am-start must run off the main thread (AdbShellBridge does net I/O).
        Thread({
            val cmd = if (component != null) {
                "am start --display $vdId -n $component"
            } else {
                "am start --display $vdId -a android.intent.action.MAIN " +
                    "-c android.intent.category.LAUNCHER $pkg"
            }
            val r = AmShellRunner.runWithRetry(
                cmd,
                timeoutMs = 5_000L,
                maxRetries = AmShellRunner.SURFACE_CREATE_MAX_RETRIES,
                backoff = AmShellRunner.EXPONENTIAL_BACKOFF,
            )
            Log.w(TAG, "projection am-start cmd=[$cmd] result=$r")
        }, "cluster-project").apply { isDaemon = true }.start()
    }

    /**
     * Own-content cluster projection — hosts a full-screen [SurfaceView]; once
     * its Surface is ready, creates a VirtualDisplay backed by it and shows a
     * [Presentation] of OUR sandboxed WebView on that VD. ilink's own UI
     * appears on the cluster without am-starting any foreign app, on the same
     * L7-safe own-VirtualDisplay group as the foreign-app cast. Passive display
     * surface — no synthetic touch is forwarded here.
     */
    private fun startContentProjection(bundleUri: String, route: String, appId: String) {
        liveProjection = this
        Log.w(TAG, "content projection start bundle=$bundleUri route=$route")
        val sv = SurfaceView(this)
        setContentView(sv)
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            private var shown = false
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (shown) return
                shown = true
                val m = resources.displayMetrics
                val w = (intent?.getIntExtra(EXTRA_PROJECT_W, 0) ?: 0)
                    .takeIf { it > 0 } ?: m.widthPixels
                val h = (intent?.getIntExtra(EXTRA_PROJECT_H, 0) ?: 0)
                    .takeIf { it > 0 } ?: m.heightPixels
                projectContentOnto(holder.surface, w, h, m.densityDpi, bundleUri, route, appId)
            }

            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })
    }

    private fun projectContentOnto(
        surface: Surface,
        w: Int,
        h: Int,
        dpi: Int,
        bundleUri: String,
        route: String,
        appId: String,
    ) {
        val dm = getSystemService(DISPLAY_SERVICE) as DisplayManager
        // Private PRESENTATION VD, same posture as the foreign-app cast — our
        // own content is what FLAG_PRESENTATION is literally for.
        val flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
        val vd = try {
            dm.createVirtualDisplay("ilink_cluster_content_vd", w, h, dpi, surface, flags)
        } catch (t: Throwable) {
            Log.e(TAG, "content createVirtualDisplay failed: ${t.message}", t)
            null
        }
        virtualDisplay = vd
        val display = vd?.display
        if (display == null) {
            Log.e(TAG, "no virtual display — content projection aborted")
            return
        }
        try {
            val p = Presentation(this, display)
            // Reuse the sandboxed secondary-surface WebView builder so the
            // cluster surface carries the IDENTICAL security posture (nav gate,
            // file-access rules) as every other secondary surface.
            val wv = SecondarySurfaceWebView.build(p.context, appId, bundleUri, route, TAG)
            p.setContentView(wv)
            p.show()
            contentPresentation = p
            webView = wv // routes onDestroy's WebView teardown
            Log.w(TAG, "content projection: Presentation shown on vdId=${display.displayId}")
        } catch (t: Throwable) {
            Log.e(TAG, "content Presentation.show failed: ${t.message}", t)
        }
    }

    override fun onDestroy() {
        stopAmapWatchdog()
        // Tear down a foreign-app projection: release our VD + stop the
        // projected app so it doesn't linger on a now-dead display.
        releaseProjection()
        liveTours.remove(this)
        surfaceId?.let { live.remove(it) }
        try {
            webView?.let {
                it.stopLoading()
                it.loadUrl("about:blank")
                it.destroy()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "webView.destroy threw: ${t.message}")
        }
        webView = null
        super.onDestroy()
    }

    /**
     * Tour-mode renderer. Builds a full-screen tile in the supplied
     * background colour with a giant "DISPLAY N" + label. Designed
     * to be identifiable from across the cabin — the user looks
     * around and confirms which physical screen this Activity
     * landed on.
     *
     * Why no WebView: the marker doesn't need scripting / mini-app
     * isolation; a plain View renders faster (no Chromium init,
     * no JS engine warmup) and never fights with amap for the
     * cluster slot the way the WebView path does. Watchdog stays
     * off — calibration probes are short (<5 s typically) and we
     * don't want amap kills happening during a calibration run.
     */
    private fun renderTourMarker() {
        val displayId = intent?.getIntExtra(EXTRA_TOUR_DISPLAY_ID, -1) ?: -1
        val color = intent?.getIntExtra(EXTRA_TOUR_COLOR_ARGB, Color.MAGENTA)
            ?: Color.MAGENTA
        val label = intent?.getStringExtra(EXTRA_TOUR_LABEL).orEmpty()
        val realDisplayId = windowManager.defaultDisplay.displayId
        Log.i(
            TAG,
            "tour marker: requested displayId=$displayId, " +
                "actual=$realDisplayId, label='$label'",
        )

        val root = android.widget.FrameLayout(this).apply {
            setBackgroundColor(color)
        }
        // Blank mode — opaque colour fill only, no marker text.
        // Repaints a just-vacated projected display so the previous
        // app's frozen last frame is replaced (Di5.1 move-stack).
        if (intent?.getStringExtra(EXTRA_TOUR_BLANK) == "1") {
            setContentView(root)
            return
        }
        val text = android.widget.TextView(this).apply {
            text = buildString {
                append("DISPLAY ")
                append(if (displayId >= 0) displayId.toString() else "?")
                if (label.isNotEmpty()) {
                    append('\n')
                    append(label)
                }
            }
            textSize = 72f
            setTextColor(Color.WHITE)
            // Black outline via shadow — keeps the giant text legible
            // on any background colour the caller picks. Cheap,
            // pre-Compose, no extra deps.
            setShadowLayer(8f, 0f, 0f, Color.BLACK)
            gravity = android.view.Gravity.CENTER
            typeface = android.graphics.Typeface.create(
                android.graphics.Typeface.SANS_SERIF,
                android.graphics.Typeface.BOLD,
            )
            val params = android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
            )
            params.gravity = android.view.Gravity.CENTER
            layoutParams = params
        }
        root.addView(text)
        setContentView(root)
    }

    /** Drop the trailing `index.html` (or whatever filename) from a
     *  bundle URI to get the install root prefix. Mirrors the helper
     *  in [SurfacePlatformPlugin]. */
    private fun installRootOf(bundleUri: String): String {
        val parsed = Uri.parse(bundleUri)
        val path = parsed.path ?: return bundleUri
        val lastSlash = path.lastIndexOf('/')
        if (lastSlash < 0) return bundleUri
        return Uri.Builder()
            .scheme(parsed.scheme)
            .authority(parsed.authority)
            .path(path.substring(0, lastSlash + 1))
            .build()
            .toString()
    }
}
