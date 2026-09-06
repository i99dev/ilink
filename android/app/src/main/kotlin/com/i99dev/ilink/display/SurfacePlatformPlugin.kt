package com.i99dev.ilink.display

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.app.Presentation
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.car.profiles.CarProfileRegistry
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import com.i99dev.ilink.pkg.AmShellResult
import com.i99dev.ilink.pkg.AmShellRunner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/**
 * `surface` family — opens a top-level rendering surface on a target
 * [Display] for a mini-app to draw on. Two paths:
 *
 *   1. **Presentation** (preferred). Standard Android API for rendering
 *      to a non-default display. Works on virtual displays the host's
 *      UID can target.
 *
 *   2. **TYPE_APPLICATION_OVERLAY fallback**. Used when
 *      [Presentation.show] is denied (e.g. on Leopard 8 the cluster's
 *      XDJA-owned virtual displays may refuse non-owner Presentation —
 *      see `.secrets/research/l8/dlink-unit/driver/projection.md`).
 *      Requires `SYSTEM_ALERT_WINDOW`, granted by `AdbBootstrap`.
 *
 * Each surface mounts a sandboxed Android [WebView] that loads the
 * calling mini-app's `bundleUri` (passed by Dart from
 * `MiniAppInstallStorage`). Security flags mirror the IVI viewer's
 * `_lockedSettings()` (`mini_app_viewer.dart:453`):
 *
 *   * JavaScript on, DOM storage on.
 *   * `allowFileAccess(FromFileURLs)` true so the bundle's
 *     `<script src="./app.js">` resolves.
 *   * `allowUniversalAccessFromFileURLs` false: a `file://` page
 *     can't xhr arbitrary http hosts.
 *   * `WebViewClient.shouldOverrideUrlLoading` rejects every URL
 *     that doesn't share the bundle's install root prefix.
 *
 * Per the slice plan ("Finish Phase A end-to-end"), the secondary
 * WebView ships **without** a host bridge (no `__i99dashHost.callHandler`,
 * no admin/family ops). Cluster pages render self-contained HTML;
 * dynamic data flows IVI→cluster via `surface.navigate({route})`
 * URL params. Adding the bridge is a follow-up.
 *
 * Wire shape, mirrored on the SDK side:
 *
 *     create({displayId, route?, appId, bundleUri}) → {surfaceId, path, displayId, route}
 *     navigate({surfaceId, route}) → {ok}
 *     destroy({surfaceId})         → {ok}
 *     list()                        → {surfaces: [{id, displayId, path, route}]}
 *
 * `path` is one of `"presentation" | "overlay" | "denied"`.
 */
class SurfacePlatformPlugin(
    private val applicationContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "ilink/surface").also {
        it.setMethodCallHandler(this)
    }

    private val dm: DisplayManager =
        applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Single-threaded worker for loopback-ADB shell calls. ADB is
     *  network I/O — forbidden on the main thread. Single-threaded
     *  so multiple `surface.create` calls against XDJA displays
     *  serialize cleanly without spawning per-call threads. */
    private val adbExecutor = Executors.newSingleThreadExecutor()

    init {
        // Defensive: if the previous host process crashed while the
        // priority-100 cluster-slot alias was enabled, the alias
        // setting persisted across boots and amap is permanently
        // displaced. Reset to disabled on startup; the next
        // surface.create on an XDJA display re-enables it.
        setSlotAliasEnabled(false)
    }

    private val surfaces = mutableMapOf<String, ActiveSurface>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> handleCreate(call, result)
            "navigate" -> handleNavigate(call, result)
            "destroy" -> handleDestroy(call, result)
            "list" -> result.success(mapOf("surfaces" to listSurfaces()))
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        mainHandler.post {
            for (s in surfaces.values.toList()) {
                tearDown(s)
            }
            surfaces.clear()
        }
        methodChannel.setMethodCallHandler(null)
        adbExecutor.shutdown()
    }

    // ── handlers ─────────────────────────────────────────────────

    private fun handleCreate(call: MethodCall, result: MethodChannel.Result) {
        val displayId = (call.argument<Number>("displayId"))?.toInt()
        if (displayId == null) {
            result.error("bad_request", "displayId required", null)
            return
        }
        val route = call.argument<String>("route") ?: "/"
        // appId + bundleUri are passed by the Dart-side surface family
        // (it resolves bundleUri via MiniAppInstallStorage). Both are
        // required for the WebView mount; absence => the mini-app isn't
        // installed locally, fail closed.
        val appId = call.argument<String>("appId")
        val bundleUri = call.argument<String>("bundleUri")
        if (appId == null || bundleUri == null) {
            result.error("bad_request", "appId + bundleUri required", null)
            return
        }
        try {
            SecondarySurfacePolicy(bundleUri).apply {
                requireOwner(applicationContext.filesDir, appId)
                resolve(route, bundleUri)
            }
        } catch (_: Exception) {
            result.error("surface_denied", "Invalid bundle or route", null)
            return
        }
        val display = dm.getDisplay(displayId)
        if (display == null) {
            result.error("display_not_found", "displayId=$displayId", null)
            return
        }

        // Same centralized policy the pkg path uses — `surface.create`
        // is the OwnContent kind. The planner is the single decision
        // point (consistency across native + mini-app surfaces); the
        // Presentation / overlay / am-start-host executor below is
        // unchanged. Today this only short-circuits a genuinely
        // unreachable target honestly instead of failing opaquely.
        val profile = CarProfileRegistry.forChain(
            MiniAppDispatcher.activeModelIds(),
        )
        val plan = DisplayLaunchPlanner.plan(
            target = DisplayLaunchPlanner.Target.Display(displayId),
            contentKind = DisplayLaunchPlanner.ContentKind.OwnContent,
            profile = profile,
            roleResolver = { id ->
                dm.getDisplay(id)?.let { DisplayRoles.roleFor(it) }
                    ?: DisplayRoles.UNKNOWN
            },
        )
        if (plan is DisplayLaunchPlanner.LaunchPlan.Unreachable) {
            result.error("surface_unreachable", plan.reason, null)
            return
        }

        val surfaceId = "sfc_${UUID.randomUUID()}"

        fun completeOnMain(block: () -> ActiveSurface) {
            mainHandler.post {
                try {
                    val active = block()
                    surfaces[surfaceId] = active
                    result.success(
                        mapOf(
                            "surfaceId" to surfaceId,
                            "path" to active.path,
                            "displayId" to displayId,
                            "route" to route,
                        ),
                    )
                } catch (t: Throwable) {
                    Log.w(
                        TAG,
                        "surface.create failed for displayId=$displayId: ${t.message}",
                    )
                    result.error(
                        "surface_denied",
                        t.message ?: t.javaClass.simpleName,
                        null,
                    )
                }
            }
        }

        // XDJA-owned displays go through `am start-activity --display N`
        // over loopback ADB (the only path that actually puts pixels on
        // the cluster MCU on Leopard 8 — see createSurface KDoc). ADB
        // is blocking net I/O, so it runs off-main. On success we
        // record the ActiveSurface on main; on WMS-transient we surface
        // a typed error so mini-apps can render a Retry button instead
        // of a permanent failure; on hard failure we fall through to
        // the overlay path on main (still won't render on XDJA but at
        // least returns truthfully).
        if (isXdjaProjection(display)) {
            adbExecutor.execute {
                val outcome = tryAmStartActivity(
                    displayId = displayId,
                    surfaceId = surfaceId,
                    route = route,
                    appId = appId,
                    bundleUri = bundleUri,
                )
                when (outcome) {
                    is AmStartOutcome.Success -> {
                        mainHandler.post {
                            surfaces[surfaceId] = outcome.surface
                            result.success(
                                mapOf(
                                    "surfaceId" to surfaceId,
                                    "path" to outcome.surface.path,
                                    "displayId" to displayId,
                                    "route" to route,
                                ),
                            )
                        }
                    }
                    is AmStartOutcome.WmsTransient -> {
                        // Don't fall through to overlay — overlay paints
                        // pixels into a different surface than the user
                        // asked for, and a WMS transient is recoverable
                        // by retry. Bubble the typed error up so the
                        // SDK can render a Retry affordance.
                        mainHandler.post {
                            result.error(
                                "surface_wms_transient",
                                "BYD WMS bug; retry",
                                null,
                            )
                        }
                    }
                    is AmStartOutcome.HardFailure -> {
                        Log.i(
                            TAG,
                            "am-start failed for displayId=$displayId " +
                                "(${outcome.reason}) — falling back to overlay",
                        )
                        completeOnMain {
                            createOverlay(displayId, display, surfaceId, route, appId, bundleUri)
                        }
                    }
                }
            }
            return
        }

        // Non-XDJA displays: standard Presentation/overlay flow on
        // the main thread. Presentation.show / wm.addView don't return
        // until the layout attaches.
        completeOnMain {
            createSurface(
                displayId = displayId,
                display = display,
                surfaceId = surfaceId,
                route = route,
                appId = appId,
                bundleUri = bundleUri,
            )
        }
    }

    private fun handleNavigate(call: MethodCall, result: MethodChannel.Result) {
        val surfaceId = call.argument<String>("surfaceId")
        val route = call.argument<String>("route") ?: "/"
        if (surfaceId == null) {
            result.error("bad_request", "surfaceId required", null)
            return
        }
        mainHandler.post {
            val active = surfaces[surfaceId]
            if (active == null) {
                result.error("surface_not_found", surfaceId, null)
                return@post
            }

            // Reload the WebView at the new route. Bundle root + route
            // pasted; the navigation gate in WebViewClient still
            // enforces install-root containment.
            val newUri = try {
                resolveRouteUri(active.bundleUri, route)
            } catch (_: Exception) {
                result.error("surface_denied", "Route outside bundle", null)
                return@post
            }
            active.route = route
            // For am-start surfaces the WebView lives inside a
            // ClusterActivity in our process — look it up via the
            // self-registry. For Presentation/overlay surfaces the
            // WebView is held directly on ActiveSurface.
            if (active.path == "am-start") {
                val ca = ClusterActivity.find(surfaceId)
                ca?.runOnUiThread { ca.loadUrlOnWebView(newUri) }
            } else {
                active.webView?.let { SecondarySurfaceWebView.navigate(it, newUri) }
            }
            result.success(mapOf("ok" to true, "route" to route))
        }
    }

    private fun handleDestroy(call: MethodCall, result: MethodChannel.Result) {
        val surfaceId = call.argument<String>("surfaceId")
        if (surfaceId == null) {
            result.error("bad_request", "surfaceId required", null)
            return
        }
        mainHandler.post {
            val active = surfaces.remove(surfaceId)
            if (active == null) {
                result.error("surface_not_found", surfaceId, null)
                return@post
            }
            tearDown(active)
            result.success(mapOf("ok" to true))
        }
    }

    private fun listSurfaces(): List<Map<String, Any?>> {
        return surfaces.values.map {
            mapOf(
                "id" to it.surfaceId,
                "displayId" to it.displayId,
                "path" to it.path,
                "route" to it.route,
            )
        }
    }

    // ── surface lifecycle ────────────────────────────────────────

    private fun createSurface(
        displayId: Int,
        display: Display,
        surfaceId: String,
        route: String,
        appId: String,
        bundleUri: String,
    ): ActiveSurface {
        // XDJA-owned displays are handled in [handleCreate] before
        // reaching here (they need an ADB worker thread). This entry
        // point is reached only for non-XDJA displays — the IVI
        // itself, or a non-fission secondary screen. Try Presentation
        // first — it composites the cleanest because it owns the
        // dialog window decor and dismiss lifecycle.
        try {
            val presentation = HostPresentation(
                outerCtx = applicationContext,
                display = display,
                surfaceId = surfaceId,
                bundleUri = bundleUri,
                route = route,
                appId = appId,
            )
            presentation.show()
            return ActiveSurface(
                surfaceId = surfaceId,
                displayId = displayId,
                path = "presentation",
                presentation = presentation,
                webView = presentation.webView,
                overlayView = null,
                route = route,
                appId = appId,
                bundleUri = bundleUri,
            )
        } catch (t: Throwable) {
            Log.i(TAG, "Presentation denied on displayId=$displayId, falling back to overlay: ${t.message}")
        }

        // Fall back to TYPE_APPLICATION_OVERLAY bound via createDisplayContext.
        return createOverlay(displayId, display, surfaceId, route, appId, bundleUri)
    }

    private fun isXdjaProjection(display: Display): Boolean {
        val name = display.name.orEmpty()
        return name.contains("fission", ignoreCase = true) ||
            name.contains("XDJAScreenProjection", ignoreCase = true)
    }

    /**
     * Launch a [ClusterActivity] onto [displayId] via loopback ADB.
     * Returns an [AmStartOutcome] — Success carries the resulting
     * [ActiveSurface]; WmsTransient signals the BYD ROM bug (caller
     * surfaces a Retry); HardFailure carries a category string the
     * caller logs / falls back to overlay on.
     *
     * Why ADB: ActivityManager-mediated launches are accepted by the
     * XDJA composer; in-process `startActivity(launchOptions)` paths
     * with `setLaunchDisplayId` require `INTERNAL_SYSTEM_WINDOW`
     * which we don't have. The shell uid (2000) launching us has the
     * implicit grant.
     *
     * Recipe (matches i99dev's dex string `am start-activity -S
     * --display`):
     *
     *     am start-activity -S \
     *         --display N \
     *         -n com.i99dev.ilink/.display.ClusterActivity \
     *         --es bundleUri 'file:///data/data/.../index.html' \
     *         --es route '/cluster.html' \
     *         --es surfaceId sfc_xxx \
     *         --es appId cluster-hello-world
     *
     * Single-quote each `--es` value so the shell doesn't try to
     * expand the path.
     *
     * MUST be called off-main (this method blocks on
     * [AdbShellBridge.shell]).
     */
    private fun tryAmStartActivity(
        displayId: Int,
        surfaceId: String,
        route: String,
        appId: String,
        bundleUri: String,
    ): AmStartOutcome {
        // Cheap pre-check: if loopback ADB hasn't been bootstrapped
        // (wireless debugging not paired yet), don't waste a 5s
        // shell-call timeout. The probe also forces a quick
        // reconnect attempt if the bridge dropped.
        val probe = AdbShellBridge.shell("echo ok", 1_500).trim()
        if (probe.startsWith("Error:")) {
            Log.w(TAG, "tryAmStartActivity: ADB unreachable ($probe)")
            return AmStartOutcome.HardFailure("adb_unreachable")
        }

        // Approach 2 — z-order hijack via priority-100 alias.
        // Enable our `ClusterSlotAlias` so the cluster service's next
        // `Intent(startBottomEmptyActivity)` lands on our activity
        // instead of amap's BottomEmptyActivity. Without this,
        // `am-start` puts our window on the same display as amap but
        // amap stays z-ordered above us.
        // Disabled again on tearDown so amap reclaims the slot when
        // the user closes the cluster mini-app.
        setSlotAliasEnabled(true)

        // NOTE: do NOT pass `-S` (force-stop). i99dev uses `-S` because
        // it launches OTHER packages onto the cluster — `-S` then only
        // kills that other package's process. We launch a ClusterActivity
        // INSIDE our own package; `-S` would force-stop com.i99dev.ilink
        // first, killing the IVI host (and the WebView running this very
        // mini-app) before the new Activity comes up. Symptom: pressing
        // an open-cluster button triggers a system "stop service?"
        // dialog and an "allow" closes the entire app.
        //
        // `--activity-multiple-task` is required: without it AM reuses
        // the existing ClusterActivity instance (delivered as
        // `onNewIntent`) and ignores `--display`, leaving every tap
        // routed to whichever display the first launch landed on.
        // Don't pass `--activity-new-task` — some Android builds reject
        // that flag at the `am` parser ("Unknown option:
        // --activity-new-task"); FLAG_ACTIVITY_NEW_TASK is implicit
        // when `am start-activity` launches from a shell session
        // anyway. Verified on Leopard 8 (Q0414).
        //
        // The full command shape (incl. `--activity-reorder-to-front`
        // to hoist above amap, and the four `--es` extras for
        // bundleUri/route/surfaceId/appId) lives in the encrypted
        // mini-app table; MiniAppShellCommands resolves the template
        // at runtime so the literals don't ship in classes.dex.
        val cmd = MiniAppShellCommands.amStartClusterActivity(
            displayId = displayId,
            component = MiniAppShellCommands.clusterActivityComponent(),
            bundleUri = bundleUri,
            route = route,
            surfaceId = surfaceId,
            appId = appId,
        )
        // Route through AmShellRunner so the BYD WMS transient
        // (`Task.java:5442` ClassCastException) gets automatic retries
        // before we surface the failure. Cluster surface creation uses
        // the surface-specific retry profile — up to 3 retries with
        // exponential backoff (250/500/1000/2000 ms) — because the
        // visible `surface_wms_transient` banner is materially worse
        // UX than a 1-2 s longer Push button settle. The classifier
        // is the single source of truth across every am-start call site.
        val amStart = AmShellRunner.runWithRetry(
            cmd = cmd,
            timeoutMs = 8_000L,
            maxRetries = AmShellRunner.SURFACE_CREATE_MAX_RETRIES,
            backoff = AmShellRunner.EXPONENTIAL_BACKOFF,
        )
        when (amStart) {
            is AmShellResult.Ok -> {
                Log.i(
                    TAG,
                    "am-start ok displayId=$displayId surfaceId=$surfaceId attempts=${amStart.attempts}",
                )
                if (amStart.attempts > 1) {
                    // Recovery-after-retry breadcrumb. INFO level so it
                    // doesn't appear as an error in Sentry's issue stream
                    // but still feeds the byd_wms_transient histogram.
                    // Lets us measure how much of the visible-banner rate
                    // SURFACE_CREATE_MAX_RETRIES is silently absorbing.

                }
            }
            is AmShellResult.WmsTransient -> {
                Log.w(TAG, "am-start hit WMS-transient bug after retries exhausted")
                // Final-attempt-failure breadcrumb — first-try failures
                // are normal noise on this ROM; only the exhausted
                // case is user-visible (yellow banner) and worth
                // investigating in Sentry.

                return AmStartOutcome.WmsTransient
            }
            is AmShellResult.HardFailure -> {
                Log.w(TAG, "am-start hard failure: ${amStart.reason} :: ${amStart.out}")
                return AmStartOutcome.HardFailure(amStart.reason)
            }
        }

        // Approach 2.1 — full slot eviction.
        //
        // Even with our priority-100 alias, amap's process keeps a
        // cached `setComponent()` reference to its own
        // `BottomEmptyActivity` and re-projects directly on
        // gear-state changes / nav events, beating our resolver.
        // `am force-stop com.example.amapservice` evicts amap's
        // current windows and clears the projection-service binding;
        // when amap respawns (it's `persistent="true"` so
        // ActivityManager auto-restarts it within ~1s) it re-runs
        // the projection handshake, but this time PackageManager
        // resolves our priority-100 alias for the slot host.
        //
        // Trade-offs:
        //  * Brief (<1s) gap where neither amap nor our content paints.
        //  * Disrupts amap's cached state — turn-by-turn nav resets,
        //    which is acceptable in the dev / parked context this
        //    feature targets.
        //  * `force-stop` over loopback ADB is shell-uid; works
        //    against amap (uid system) on Leopard 8 because BYD's
        //    `frameworks/base` allows shell to force-stop system
        //    apps (verified 2026-05-02).
        //
        // The matching `am force-stop` on tearDown is intentionally
        // omitted — amap auto-respawns on its own; we don't want to
        // race it back into the slot after the user's done. force-stop
        // is best-effort (any failure here doesn't invalidate the
        // surface we just created) so we route through runOnce, log a
        // hard failure, and keep going.
        val amapStop = AmShellRunner.runOnce(
            MiniAppShellCommands.amForceStopAmap(), 3_000L,
        )
        when (amapStop) {
            is AmShellResult.Ok -> {
                if (amapStop.out.isNotEmpty() && !amapStop.out.equals("ok", true)) {
                    Log.i(TAG, "amap force-stop output: ${amapStop.out}")
                } else {
                    Log.i(TAG, "amap force-stopped — slot now available")
                }
            }
            is AmShellResult.WmsTransient -> {
                Log.i(TAG, "amap force-stop wms_transient (best-effort): ${amapStop.out.take(120)}")
            }
            is AmShellResult.HardFailure -> {
                Log.w(TAG, "amap force-stop hard failure (best-effort): ${amapStop.reason}")
            }
        }
        return AmStartOutcome.Success(
            ActiveSurface(
                surfaceId = surfaceId,
                displayId = displayId,
                path = "am-start",
                presentation = null,
                webView = null,
                overlayView = null,
                route = route,
                appId = appId,
                bundleUri = bundleUri,
            ),
        )
    }

    /**
     * Outcome of [tryAmStartActivity] — three-way split so the caller
     * can route a WMS-transient (recoverable; user-facing Retry) vs a
     * hard failure (overlay fallback if non-XDJA, typed error
     * otherwise) without re-parsing shell output.
     */
    private sealed class AmStartOutcome {
        data class Success(val surface: ActiveSurface) : AmStartOutcome()
        object WmsTransient : AmStartOutcome()
        data class HardFailure(val reason: String) : AmStartOutcome()
    }

    private fun createOverlay(
        displayId: Int,
        display: Display,
        surfaceId: String,
        route: String,
        appId: String,
        bundleUri: String,
    ): ActiveSurface {
        val displayCtx = applicationContext.createDisplayContext(display)
        val overlayWm = displayCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val webView = newSandboxedWebView(displayCtx, appId, bundleUri, route)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.START or Gravity.TOP
        }
        overlayWm.addView(webView, params)
        return ActiveSurface(
            surfaceId = surfaceId,
            displayId = displayId,
            path = "overlay",
            presentation = null,
            webView = webView,
            overlayView = webView,
            overlayWm = overlayWm,
            route = route,
            appId = appId,
            bundleUri = bundleUri,
        )
    }

    private fun tearDown(s: ActiveSurface) {
        // am-start path: the WebView lives inside a ClusterActivity
        // running in our own process. Look it up by surfaceId in the
        // self-registry and finish() — that triggers the activity's
        // onDestroy which tears down the WebView.
        if (s.path == "am-start") {
            try {
                ClusterActivity.find(s.surfaceId)?.finish()
            } catch (t: Throwable) {
                Log.w(TAG, "ClusterActivity.finish threw: ${t.message}")
            }
            // Hand the slot back to amap — disable the priority-100
            // alias we enabled in tryAmStartActivity. Done only when
            // every am-start surface has been destroyed; if other
            // mini-apps still have surfaces on a cluster display we
            // keep the alias hot. See `CLUSTER_Z_ORDER.md`.
            val anyAmStartLeft = surfaces.values.any {
                it.surfaceId != s.surfaceId && it.path == "am-start"
            }
            if (!anyAmStartLeft) {
                setSlotAliasEnabled(false)
            }
            return
        }
        try {
            s.webView?.let {
                it.stopLoading()
                it.loadUrl("about:blank")
                it.destroy()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "webView.destroy threw: ${t.message}")
        }
        try {
            s.presentation?.dismiss()
        } catch (t: Throwable) {
            Log.w(TAG, "presentation.dismiss threw: ${t.message}")
        }
        try {
            s.overlayWm?.removeView(s.overlayView)
        } catch (t: Throwable) {
            Log.w(TAG, "overlay removeView threw: ${t.message}")
        }
    }

    /**
     * Build a [WebView] with the same security posture as the IVI's
     * primary mini-app viewer. Mirrors the flags in
     * `mini_app_viewer.dart:453-463`:
     *
     *   * JavaScript on, DOM storage on.
     *   * `allowFileAccessFromFileURLs` true (so the bundle's
     *     `file://`-served `<script>`s can fetch siblings).
     *   * `allowUniversalAccessFromFileURLs` false (a `file://` page
     *     can't reach arbitrary http hosts).
     *   * `mediaPlaybackRequiresUserGesture` true.
     *
     * Navigation gate: any URL that doesn't share the install-root
     * prefix is cancelled — same rule as
     * `mini_app_viewer.dart::_navigationAllowed`. Guards against a
     * compromised page navigating to `https://attacker.com/...` or
     * back into another mini-app's `file://` bundle.
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun newSandboxedWebView(
        ctx: Context,
        appId: String,
        bundleUri: String,
        route: String,
    ): WebView = SecondarySurfaceWebView.build(ctx, appId, bundleUri, route, TAG)

    // ── helpers ──────────────────────────────────────────────────

    /**
     * Resolve a `route` ("/", "/cluster", "/cluster.html") against
     * the bundle's `index.html` URI. Mirrors the SDK's contract:
     * routes are bundle-relative paths (regex `^/[A-Za-z0-9._\-/]*$`,
     * gated by [SurfaceFamily._NavigateHandler.paramSchema]).
     */
    private fun resolveRouteUri(bundleUri: String, route: String): String =
        SecondarySurfaceWebView.resolveRouteUri(bundleUri, route)


    private class HostPresentation(
        outerCtx: Context,
        display: Display,
        val surfaceId: String,
        val bundleUri: String,
        val route: String,
        val appId: String,
    ) : Presentation(outerCtx, display) {
        var webView: WebView? = null
            private set

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            // Both creation paths (Presentation, in-window overlay) build
            // the WebView from the same factory so the security rules
            // (JS, file-URL access, install-root navigation gate) can't
            // drift between the two surfaces. See [SecondarySurfaceWebView].
            val wv = SecondarySurfaceWebView.build(context, appId, bundleUri, route, TAG)
            setContentView(wv)
            webView = wv
        }

        override fun onStop() {
            super.onStop()
            try {
                webView?.stopLoading()
                webView?.loadUrl("about:blank")
                webView?.destroy()
            } catch (_: Throwable) {
                // Best-effort cleanup.
            }
            webView = null
        }
    }

    private data class ActiveSurface(
        val surfaceId: String,
        val displayId: Int,
        val path: String,
        val presentation: Presentation?,
        val webView: WebView?,
        val overlayView: View?,
        val overlayWm: WindowManager? = null,
        var route: String,
        val appId: String,
        val bundleUri: String,
    )

    /**
     * Toggle the priority-100 cluster-slot alias.
     *
     * `enabled = true` — the next `Intent(startBottomEmptyActivity)`
     * the BYD projection-manager service issues will resolve to our
     * [ClusterActivity] (via the alias) instead of amap's
     * `BottomEmptyActivity`. This is the "hijack the slot" approach.
     *
     * `enabled = false` — alias is removed from the IntentResolver,
     * amap's filter wins again. Restoring this on teardown is
     * critical: leaving the alias hot would permanently displace
     * amap's ADAS map.
     *
     * `DONT_KILL_APP` keeps our own process alive across the toggle
     * (the host's MainActivity stays running, the IVI WebView
     * doesn't blink). The alias state IS persisted across boots,
     * so a crash with the alias enabled would leave us hijacking
     * the slot until next launch — `MainActivity.onCreate` resets
     * to disabled defensively.
     */
    private fun setSlotAliasEnabled(enabled: Boolean) {
        try {
            val pm = applicationContext.packageManager
            val component = ComponentName(
                applicationContext,
                "com.i99dev.ilink.display.ClusterSlotAlias",
            )
            val target = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            pm.setComponentEnabledSetting(
                component, target, PackageManager.DONT_KILL_APP,
            )
            Log.i(TAG, "ClusterSlotAlias enabled=$enabled")
        } catch (t: Throwable) {
            Log.w(TAG, "setSlotAliasEnabled($enabled) threw: ${t.message}")
        }
    }

    companion object {
        private const val TAG = "SurfacePlatformPlugin"
    }
}
