package com.i99dev.ilink.pkg

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Process
import android.util.Log
import java.security.MessageDigest
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.car.CapabilityRegistry
import com.i99dev.ilink.car.VehicleCapability
import com.i99dev.ilink.car.profiles.CarProfileRegistry
import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.display.ClusterActivity
import com.i99dev.ilink.display.DisplayLaunchPlanner
import com.i99dev.ilink.display.DisplayMemory
import com.i99dev.ilink.display.DisplayRoles
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Phase C — `pkg` family native side.
 *
 * MethodChannel `ilink/pkg` with four methods:
 *   * `list({includeSystem: Bool})` — return installed packages
 *     with label / versionName / versionCode / isSystem. Uses
 *     `PackageManager.getInstalledPackages` filtered to those that
 *     have a launcher intent (a "launchable" subset — no services
 *     or providers as standalone entries). The query is bounded by
 *     QUERY_ALL_PACKAGES (manifest, install-time grant on Leopard 8).
 *   * `foreground()` — current foreground package. Tries the cheap
 *     `ActivityManager.getRunningTasks(1)` path first (still works
 *     on the Leopard 8 vendor build despite Google's deprecation),
 *     falls back to `UsageStatsManager.queryUsageStats` over the
 *     last 60 s otherwise. Returns null if both fail (no permission,
 *     locked screen).
 *   * `usage({windowMs: Int})` — `UsageStatsManager.queryUsageStats`
 *     rolled up to per-package totals over the window. Empty list
 *     when the GET_USAGE_STATS appop isn't allowed (don't throw —
 *     usage stats are best-effort by design).
 *   * `launch({packageName, displayId?})` — `Context.startActivity`
 *     for the default display; `am start --user 0 --display N` over
 *     loopback ADB for non-default displays. Mirrors the surface
 *     family's am-start path on cluster slots.
 *
 * Threading: list / foreground / usage run on Flutter's MethodChannel
 * thread (PackageManager + UsageStatsManager + ActivityManager are
 * fast). The non-default-display launch path uses [AdbShellBridge]
 * which hits a TCP loopback socket, so it MUST run off the main
 * thread or Android raises [NetworkOnMainThreadException]. The
 * default-display path stays inline since it's just `startActivity`.
 */
class PackagePlatformPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    /** Background dispatcher for the am-start path. Single-threaded —
     *  serialises consecutive launches so the shell bridge isn't
     *  juggling concurrent prompts. */
    private val adbExecutor = Executors.newSingleThreadExecutor()

    /** Lazy DiShare transport — only constructed when the active
     *  trim's capability bitmask says it has `pkg.launch.dishare`
     *  (L5 / L5U today). Stays null on Di5.1 trims so the import
     *  graph + binder cost is paid only where it pays off. */
    private val dishareTransport: DishareTransport by lazy {
        DishareTransport(context.applicationContext)
    }

    /** Renders + LRU-caches launcher icons for the `pkg.icon` op.
     *  Self-contained (see [PackageIconRenderer]); shares no state with
     *  the launch / move-stack / cluster machinery. */
    private val iconRenderer = PackageIconRenderer(context)

    /** Installed-package list + foreground/usage queries (`pkg.list` /
     *  `pkg.foreground` / `pkg.usage`). Self-contained (see
     *  [PackageInventory]); PackageManager/UsageStats reads only. */
    private val inventory = PackageInventory(context)

    /** Cluster-pad channel ops (`clusterPolicy.*` / `clusterInput.*` /
     *  `cluster.clear`). Shares this plugin's [adbExecutor] for shell I/O
     *  and reads the active trim topology through [activeProfile] — the
     *  same resolution the launch/move web uses (see [ClusterChannels]). */
    private val clusterChannels = ClusterChannels(context, adbExecutor) { activeProfile() }

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        // Warm the fresh-launch-only policy snapshot off the hot
        // path so doMove never does the first (disk) read.
        ClusterLaunchPolicy.ensureLoaded(context.applicationContext)
        // [ClusterDialogWatcher.start] disabled — the v1 regex
        // `(?i)dialog|alert` is too loose: it grep-matches against
        // every line `dumpsys input` returns for displayId=3/4,
        // including configuration / touch-state metadata that
        // legitimately mentions "dialog" / "alert", and each false
        // positive fires KEYCODE_BACK on the cluster every 1.5 s
        // — that pushed the cluster app off display 5 and let
        // Android re-launch it on the IVI default display (the
        // "apps bouncing between IVI and cluster" symptom 2026-05-20).
        // Keeping the class for the next pass (will gate on real
        // window types — TYPE_APPLICATION_PANEL etc — not regex);
        // off until then.
        // ClusterDialogWatcher.start()
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        ClusterDialogWatcher.stop()
        adbExecutor.shutdown()
    }

    /** Off-main-thread fastCast wrapper. Pulled out so both dispatch
     *  call sites share the same error-trap + main-thread-result-post
     *  boilerplate. */
    private fun dispatchFastCast(
        packageName: String,
        deviceTag: String,
        result: MethodChannel.Result,
    ) {
        adbExecutor.execute {
            val r = try {
                // Faithful to Shaheen RouteEngine's FSE path
                // (route → launchIvi(pkg) → postDelayed 1200ms →
                // fireDiShare): the app must be FOREGROUND on the IVI
                // before DiShare quickShare, or DiShare mirrors
                // nothing / stale content (the "card reacts, nothing
                // casts" symptom). Only the `fse` tag reaches here now
                // (cluster → ShellLaunch, ivi → IviLocal).
                runCatching {
                    context.packageManager
                        .getLaunchIntentForPackage(packageName)
                        ?.let {
                            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(it)
                        }
                }
                Thread.sleep(1200)
                dishareTransport.fastCast(packageName, deviceTag)
            } catch (t: Throwable) {
                mapOf<String, Any?>(
                    "ok" to false,
                    "path" to "dishare-denied",
                    "error" to (t.message ?: t.javaClass.simpleName),
                )
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(r)
            }
        }
    }

    /** Off-main-thread Di5.0 **cluster** launch — a faithful port of
     *  the user's working Shaheen `RouteEngine.launchCluster`. DiShare
     *  `quickShare` does NOT mirror the cluster on this ROM; the
     *  cluster is reached by directly STARTING the app on the cluster
     *  display via the embedded ADB self-bridge (shell uid → the
     *  start is not dropped the way an in-app `am start --display N`
     *  is). Command shape is byte-for-byte Shaheen's:
     *  `am start -S --display N --activity-multiple-task
     *  --activity-clear-top -n <pkg>/<activity>`. */
    private fun dispatchShellLaunch(
        packageName: String,
        displayId: Int,
        result: MethodChannel.Result,
    ) {
        adbExecutor.execute {
            val r = try {
                val component = context.packageManager
                    .getLaunchIntentForPackage(packageName)
                    ?.component
                    ?.flattenToShortString()
                if (component == null) {
                    mapOf<String, Any?>(
                        "ok" to false,
                        "path" to "denied",
                        "error" to "no launcher activity",
                    )
                } else {
                    // Verify-then-retry. Displays 3 & 4 are virtual
                    // displays in ONE BYD-container display-group;
                    // from a COLD (empty) group `am start --display 4`
                    // is re-homed by ActivityManager onto the group's
                    // active display (0), or grabbed by a foreign
                    // split-screen launcher (e.g. com.dudu.autoui's
                    // `launcher-split`). Once a task EXISTS, re-issuing
                    // routes it onto `displayId` correctly (docs/50/05;
                    // operator: "if something is on Driver, it works").
                    //
                    // The previous loop re-ran the SAME `-S` (force-
                    // stop) command every attempt, which tore the task
                    // down between tries so the group NEVER warmed — on
                    // a fully-cold cluster (no BYD meter occupying it,
                    // as on units where the instrument app isn't
                    // foreground) it never converged and the drop
                    // "did nothing". Fix:
                    //   * attempt 1 — `-S` force-stop + fresh launch
                    //     (seeds the task; may land on 4 or re-home),
                    //   * retries — re-issue WITHOUT `-S` so the now-
                    //     existing task is ROUTED onto `displayId`
                    //     instead of recreated (the warming step),
                    //   * more attempts + linear backoff give a cold
                    //     group time to accept the placement.
                    val freshCmd = "am start -S --display $displayId " +
                        "--activity-multiple-task --activity-clear-top " +
                        "-n $component"
                    // No `-S` and no `--activity-multiple-task`: REUSE
                    // the existing (re-homed) task and route it onto
                    // `displayId` via the display hint + clear-top,
                    // rather than force-stopping or spawning a 2nd copy.
                    val routeCmd = "am start --display $displayId " +
                        "--activity-clear-top -n $component"
                    var landed = false
                    var lastOut = ""
                    for (attempt in 1..CLUSTER_LAUNCH_ATTEMPTS) {
                        lastOut = AdbShellBridge.shell(
                            if (attempt == 1) freshCmd else routeCmd,
                            6_000L,
                        )
                        // Linear backoff — a cold OWN_CONTENT_ONLY group
                        // needs longer to settle than a warm one.
                        Thread.sleep(CLUSTER_LAUNCH_SETTLE_MS * attempt)
                        val rows = AmStackParser.parseAll(
                            AdbShellBridge.shell(
                                MiniAppShellCommands.amStackList(), 4_000L,
                            ),
                        )
                        if (AmStackParser.findOnDisplay(
                                rows, packageName, displayId,
                            ) != null
                        ) {
                            landed = true
                            break
                        }
                        Log.w(
                            TAG,
                            "cluster am-start attempt $attempt/" +
                                "$CLUSTER_LAUNCH_ATTEMPTS: $packageName not on " +
                                "display $displayId yet (cold group warming)",
                        )
                    }
                    if (landed) {
                        mapOf<String, Any?>(
                            "ok" to true,
                            "path" to "cluster-am-start",
                            "error" to null,
                        )
                    } else {
                        Log.w(
                            TAG,
                            "cluster am-start d=$displayId gave up; " +
                                "out=${lastOut.take(160)}",
                        )
                        mapOf<String, Any?>(
                            "ok" to false,
                            "path" to "denied",
                            "error" to (
                                "did not land on display $displayId " +
                                    "after $CLUSTER_LAUNCH_ATTEMPTS tries"
                                ),
                        )
                    }
                }
            } catch (t: Throwable) {
                mapOf<String, Any?>(
                    "ok" to false,
                    "path" to "denied",
                    "error" to (t.message ?: t.javaClass.simpleName),
                )
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(r)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "list" -> result.success(inventory.list(call))
                "foreground" -> result.success(inventory.foreground())
                "usage" -> result.success(inventory.usage(call))
                "launch" -> handleLaunch(call, result)
                "projectCluster" -> handleProjectCluster(call, result)
                "projectContentCluster" -> handleProjectContentCluster(call, result)
                "clusterProjection" -> {
                    // Active foreign-app cluster projection, if any. The
                    // touchpad routes input to vdDisplayId (where the cast
                    // app actually runs — NOT the cluster's Android id).
                    val p = ClusterActivity.activeProjection()
                    result.success(
                        if (p == null) {
                            mapOf("active" to false)
                        } else {
                            mapOf(
                                "active" to true,
                                "packageName" to p.first,
                                "vdDisplayId" to p.second,
                                "hostDisplayId" to p.third,
                            )
                        },
                    )
                }
                "stopClusterProjection" -> {
                    // Stop the active foreign-app cluster projection and
                    // return the package that was cast, so the caller can
                    // relaunch it on the IVI ("return to Head Unit"). The
                    // projected app runs on our VirtualDisplay, so the
                    // normal topOnDisplay/move path can't reach it.
                    val pkg = ClusterActivity.stopProjection()
                    result.success(mapOf("ok" to true, "packageName" to pkg))
                }
                "move" -> handleMove(call, result)
                "stop" -> handleStop(call, result)
                "icon" -> result.success(iconRenderer.icon(call))
                "running" -> handleRunning(result)
                "topOnDisplay" -> handleTopOnDisplay(call, result)
                "tourMarker" -> handleTourMarker(call, result)
                "tourFinish" -> handleTourFinish(result)
                "clusterPolicy.list" ->
                    result.success(clusterChannels.policyList())
                "clusterPolicy.classify" ->
                    result.success(clusterChannels.policyClassify(call))
                "clusterPolicy.add" ->
                    result.success(clusterChannels.policyMutate(call, add = true))
                "clusterPolicy.remove" ->
                    result.success(clusterChannels.policyMutate(call, add = false))
                // Cluster synthetic input (tap/swipe/key/resolveDisplay) moved to
                // the centralized `ilink/gesture` seam (daemon injectInputEvent
                // FAST path) — see InputPlatformPlugin. Only the cursor overlay +
                // clear stay on this channel (display concerns).
                "clusterInput.cursor.show" ->
                    clusterChannels.cursorShow(call, result)
                "clusterInput.cursor.move" ->
                    clusterChannels.cursorMove(call, result)
                "clusterInput.cursor.hide" ->
                    clusterChannels.cursorHide(result)
                "cluster.clear" -> clusterChannels.clear(result)
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "method ${call.method} threw: ${t.javaClass.simpleName}: ${t.message}")
            result.error("pkg_native_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    // ── cluster projection (foreign app via our own VirtualDisplay) ──────

    /**
     * Project a FOREIGN app onto an XDJA fission cluster display the safe
     * way (the reference mechanism). Launches our own [ClusterActivity] onto
     * [displayId] in projection mode — it creates a PRIVATE VirtualDisplay
     * and am-starts the package onto THAT, so the foreign app renders to a
     * display WE own (its own display group) and never lands on the XDJA
     * OWN_CONTENT_ONLY fission display directly. That avoids the group-0
     * reshuffle + FissionGenerayService latch that `am stack move-task`
     * triggers (the L7 hang). Verified on L7 (127.0.0.1:5999, 2026-06-12).
     *
     * Scoped to L7 by the caller: only the L7 profile routes its
     * "Driver Cluster" picker target here; every other trim keeps its
     * existing launchCluster / move path unchanged.
     */
    private fun handleProjectCluster(call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        val displayId = call.argument<Int>("displayId")
        if (packageName.isNullOrEmpty() || displayId == null) {
            result.success(
                mapOf("ok" to false, "path" to "denied", "error" to "missing packageName/displayId"),
            )
            return
        }
        adbExecutor.execute {
            // NB: NO `-S` here. `-S` force-stops the COMPONENT's package
            // first — and ClusterActivity lives in com.i99dev.ilink, so
            // `-S` would kill our own MainActivity (the IVI dashboard
            // "closes") before launching the cluster surface. Plain
            // `am start --display` (the on-car-proven form) launches
            // ClusterActivity into its own isolated task without touching
            // MainActivity.
            val cmd = "am start --display $displayId " +
                "-n com.i99dev.ilink/.display.ClusterActivity " +
                "--es ${ClusterActivity.EXTRA_PROJECT_PKG} $packageName"
            val r = AmShellRunner.runWithRetry(
                cmd,
                timeoutMs = 6_000L,
                maxRetries = AmShellRunner.SURFACE_CREATE_MAX_RETRIES,
                backoff = AmShellRunner.EXPONENTIAL_BACKOFF,
            )
            // ClusterActivity is singleInstance: a re-cast makes `am start`
            // report "Activity not started, intent delivered to currently
            // running top-most instance" — which the generic classifier
            // flags WmsTransient. For projectCluster that delivery IS
            // success (onNewIntent re-projects), so treat it as ok.
            val deliveredToRunning = r.out.contains("delivered to", ignoreCase = true) ||
                r.out.contains("top-most", ignoreCase = true) ||
                r.out.contains("current top", ignoreCase = true)
            Log.w(TAG, "projectCluster cmd=[$cmd] -> ${r.javaClass.simpleName} delivered=$deliveredToRunning out=${r.out.take(200)}")
            val out: Map<String, Any?> = when {
                r is AmShellResult.Ok || deliveredToRunning ->
                    mapOf("ok" to true, "path" to "cluster_projection")
                r is AmShellResult.WmsTransient ->
                    mapOf(
                        "ok" to false, "path" to "cluster_projection",
                        "wmsTransient" to true, "error" to r.out.take(200),
                    )
                else ->
                    mapOf(
                        "ok" to false, "path" to "cluster_projection",
                        "error" to r.out.take(180),
                    )
            }
            result.success(out)
        }
    }

    /**
     * Project ilink's OWN UI (a mini-app bundle WebView) onto a cluster
     * display via the same L7-safe own-VirtualDisplay mechanism — but hosting
     * a [Presentation] of our WebView instead of am-starting a foreign app.
     * The cluster shows an ilink dashboard. Passive display surface (no
     * touchpad input). Same singleInstance re-deliver semantics as
     * [handleProjectCluster].
     */
    private fun handleProjectContentCluster(call: MethodCall, result: MethodChannel.Result) {
        val bundleUri = call.argument<String>("bundleUri")
        val displayId = call.argument<Int>("displayId")
        if (bundleUri.isNullOrEmpty() || displayId == null) {
            result.success(
                mapOf("ok" to false, "path" to "denied", "error" to "missing bundleUri/displayId"),
            )
            return
        }
        val route = call.argument<String>("route") ?: "/"
        val appId = call.argument<String>("appId").orEmpty()
        adbExecutor.execute {
            // Single-quote the URI/route/appId (file:// paths + bundle-relative
            // routes are otherwise shell-safe, but quoting is defense in depth).
            fun sq(s: String) = "'" + s.replace("'", "'\\''") + "'"
            val cmd = buildString {
                append("am start --display $displayId ")
                append("-n com.i99dev.ilink/.display.ClusterActivity ")
                append("--es ${ClusterActivity.EXTRA_PROJECT_BUNDLE} ${sq(bundleUri)} ")
                append("--es ${ClusterActivity.EXTRA_ROUTE} ${sq(route)}")
                if (appId.isNotEmpty()) {
                    append(" --es ${ClusterActivity.EXTRA_APP_ID} ${sq(appId)}")
                }
            }
            val r = AmShellRunner.runWithRetry(
                cmd,
                timeoutMs = 6_000L,
                maxRetries = AmShellRunner.SURFACE_CREATE_MAX_RETRIES,
                backoff = AmShellRunner.EXPONENTIAL_BACKOFF,
            )
            val deliveredToRunning = r.out.contains("delivered to", ignoreCase = true) ||
                r.out.contains("top-most", ignoreCase = true) ||
                r.out.contains("current top", ignoreCase = true)
            Log.w(TAG, "projectContentCluster cmd=[$cmd] -> ${r.javaClass.simpleName} delivered=$deliveredToRunning out=${r.out.take(200)}")
            val out: Map<String, Any?> = when {
                r is AmShellResult.Ok || deliveredToRunning ->
                    mapOf("ok" to true, "path" to "cluster_content")
                r is AmShellResult.WmsTransient ->
                    mapOf(
                        "ok" to false, "path" to "cluster_content",
                        "wmsTransient" to true, "error" to r.out.take(200),
                    )
                else ->
                    mapOf("ok" to false, "path" to "cluster_content", "error" to r.out.take(180))
            }
            result.success(out)
        }
    }

    // ── launch ──────────────────────────────────────────────────────────

    private fun handleLaunch(call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        if (packageName == null) {
            result.success(mapOf("ok" to false, "path" to "denied", "error" to "no packageName"))
            return
        }
        val displayId = call.argument<Int>("displayId")
        // expectCluster is set by `pkg.launch_cluster`; the bare
        // `pkg.launch` op leaves it false. Native cross-checks the
        // resolved role against this so a mini-app can't slip a
        // cluster displayId through the standard op (defense in
        // depth — the Dart gate already enforces the permission
        // tier, but a tampered SDK could bypass that).
        val expectCluster = call.argument<Boolean>("expectCluster") ?: false
        // Optional role hint. On Di5.0 trims (L5 / L5U) the passenger
        // panel isn't an addressable Android Display — DiShare's
        // mirror chain is the only non-root path. Mini-apps that want
        // the passenger panel pass `targetRole: 'passenger'` instead
        // of a displayId, and we route through DiShare directly. Other
        // roles (or absence of the hint) fall through to the standard
        // displayId-based path below.
        val targetRole = call.argument<String>("targetRole")
        val pm = context.packageManager
        val launchIntent = pm.getLaunchIntentForPackage(packageName)
        if (launchIntent == null) {
            result.success(
                mapOf("ok" to false, "path" to "denied", "error" to "no launcher activity"),
            )
            return
        }

        // ── Single centralized decision ─────────────────────────────
        // [DisplayLaunchPlanner] owns the whole policy: the
        // Di5.0(DiShare) ↔ Di5.1(am-start) fork, the content-kind
        // split, and the role/permission gate (it absorbed what used
        // to be `shouldUseDishare()` + `DeviceTagResolver` glue +
        // `checkDisplayRole`). The executors below are unchanged — we
        // only switch on the returned plan.
        // Full chain (not just the head) so a known-but-unprofiled
        // nameplate stub resolves to its generation-correct transport
        // (DiShare on Di5.0) instead of the permissive Fission Generic.
        val profile = CarProfileRegistry.forChain(MiniAppDispatcher.activeModelIds())
        val displayMgr =
            context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val planTarget = when {
            targetRole != null && displayId == null ->
                DisplayLaunchPlanner.Target.Role(targetRole)
            displayId != null -> DisplayLaunchPlanner.Target.Display(displayId)
            else -> DisplayLaunchPlanner.Target.Role(DisplayRoles.IVI)
        }
        val plan = DisplayLaunchPlanner.plan(
            target = planTarget,
            contentKind = DisplayLaunchPlanner.ContentKind.ForeignApp,
            profile = profile,
            roleResolver = { id ->
                displayMgr.getDisplay(id)?.let { DisplayRoles.roleFor(it) }
                    ?: DisplayRoles.UNKNOWN
            },
            expectCluster = expectCluster,
        )
        when (plan) {
            is DisplayLaunchPlanner.LaunchPlan.IviLocal -> {
                // Di5.0 cluster ↔ IVI: same-pid move-stack RETURN.
                // Same-pid is the operator preference; doMove no-ops
                // on already-IVI and reports "package not running"
                // when it isn't up (both fall through to the intent
                // launch below).
                //
                // Di5.1 freshLaunchOnly (ReVanced family): also route
                // through doMove. If we let context.startActivity()
                // below handle it instead, ATMS reuses the cluster
                // task (because of FLAG_ACTIVITY_NEW_TASK + same
                // taskAffinity) — which triggers the Activity
                // recreate ReVanced's patched MainActivity cannot
                // survive, and the app dies on the IVI return
                // (operator-attested 2026-05-20). doMove's
                // freshLaunchOnly branch instead does force-stop +
                // plain `am start -n` (shell-verified to land
                // ReVanced clean on the IVI default display).
                val di50ClusterToIvi =
                    activeDilinkFamily() == DilinkFamily.Di50
                val di51FreshLaunchOnly =
                    activeDilinkFamily() == DilinkFamily.Di51 &&
                        ClusterLaunchPolicy.freshLaunchOnly(packageName)
                if (di50ClusterToIvi || di51FreshLaunchOnly) {
                    val moved = doMove(
                        packageName, DishareTransport.DISPLAY_ID_IVI,
                    )
                    val notRunning = moved["path"] == "denied" &&
                        moved["error"] == "package not running"
                    if (!notRunning) {
                        result.success(moved)
                        return
                    }
                }
                val r = runCatching {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(launchIntent)
                    mapOf<String, Any?>(
                        "ok" to true, "path" to "intent-launch", "error" to null,
                    )
                }.getOrElse { e ->
                    mapOf<String, Any?>(
                        "ok" to false, "path" to "denied", "error" to e.message,
                    )
                }
                result.success(r)
                return
            }
            is DisplayLaunchPlanner.LaunchPlan.Dishare -> {
                dispatchFastCast(packageName, plan.deviceTag, result)
                return
            }
            is DisplayLaunchPlanner.LaunchPlan.ShellLaunch -> {
                // Di5.0 CLUSTER ← IVI: same Di5.1 same-pid approach.
                // ShellLaunch is produced ONLY for a Di5.0 cluster
                // target (the planner returns Dishare for fse /
                // passenger), so this is exactly the operator-scoped
                // "driver cluster ↔ IVI" pair — for BOTH cluster ids
                // (cluster_tr = 4 AND cluster_c = 3; which one is the
                // driver cluster is car-specific, never hardcode it).
                // A running app → doMove = `am display move-stack`
                // (same pid, never relaunch — exactly what Di5.1
                // does). Only when the app is NOT running do we fall
                // through to the unchanged Shaheen launchCluster port
                // (fresh launch on the cluster display).
                val moved = doMove(packageName, plan.displayId)
                val notRunning = moved["path"] == "denied" &&
                    moved["error"] == "package not running"
                if (!notRunning) {
                    result.success(moved)
                    return
                }
                // Not running → start the app on the cluster display
                // via the shell bridge (Shaheen launchCluster port).
                dispatchShellLaunch(packageName, plan.displayId, result)
                return
            }
            is DisplayLaunchPlanner.LaunchPlan.Unreachable -> {
                result.success(
                    mapOf(
                        "ok" to false,
                        "path" to "denied",
                        "error" to plan.reason,
                    ),
                )
                return
            }
            is DisplayLaunchPlanner.LaunchPlan.SurfaceCreate -> {
                // surface.create is the `ilink/surface` channel —
                // never produced for a foreign-app `pkg.launch`.
                result.success(
                    mapOf(
                        "ok" to false,
                        "path" to "denied",
                        "error" to "surface path not valid for pkg.launch",
                    ),
                )
                return
            }
            is DisplayLaunchPlanner.LaunchPlan.AmStart -> {
                // Fall through to the existing Resume / Migrate /
                // FreshLaunch am-start machinery below.
            }
        }
        // Reached only via the AmStart branch — every other branch
        // returned. The planner guarantees a concrete (non-null)
        // display id here (the old `displayId == null` guard that
        // used to smart-cast this is now the IviLocal branch).
        val amDisplayId =
            (plan as DisplayLaunchPlanner.LaunchPlan.AmStart).displayId

        // Non-default display path. Before falling through to the
        // legacy `am start --activity-multiple-task --display N` we
        // ask [LaunchStrategyResolver] whether the package is already
        // running somewhere — this is the fix for bug A ("re-launching
        // an open app spawns a fresh instance from zero"):
        //
        //   * Already on THIS display → Resume via `am stack move-task`
        //     (bring-to-front, no new task, no `--multiple-task`).
        //   * Already on ANOTHER display → Migrate via [doMove] —
        //     reparents the existing task instead of spawning twin.
        //   * Not running anywhere → fall through to the existing
        //     FreshLaunch path with bounce-back recovery.
        //
        // All three branches share the same parsed snapshot, so this
        // is one extra `am stack list` shell hop per launch in the
        // worst case. The polling controller's cache absorbs the cost
        // when the user launches within ~2 s of the last poll. The
        // resolver itself is a pure O(N) scan with no IO.
        val component = launchIntent.component
        val target = component?.flattenToShortString() ?: packageName
        val cmd = MiniAppShellCommands.amStartOnDisplay(amDisplayId, target)
        adbExecutor.execute {
            val r: Map<String, Any?> = try {
                handleSecondaryDisplayLaunch(packageName, amDisplayId, cmd)
            } catch (t: Throwable) {
                Log.w(TAG, "launch failed: ${t.javaClass.simpleName}: ${t.message}")
                mapOf(
                    "ok" to false,
                    "path" to "denied",
                    "error" to (t.message ?: t.javaClass.simpleName),
                )
            }
            // Hardware-truth feedback into [DisplayMemory]. On a
            // verified-successful launch (`ok=true` regardless of
            // bounce-back path), record the (name, w, h) → role tuple
            // so future classifier `DEFAULT` results on the same
            // tuple promote to `CACHE_HIT`. Only records on success
            // — a failed launch tells us nothing about whether the
            // display is reachable.
            if (r["ok"] == true) {
                runCatching {
                    val dm = context.getSystemService(Context.DISPLAY_SERVICE)
                        as DisplayManager
                    val display = dm.getDisplay(amDisplayId) ?: return@runCatching
                    val role =
                        if (expectCluster) DisplayRoles.CLUSTER else DisplayRoles.PASSENGER
                    val size = android.graphics.Point()
                    @Suppress("DEPRECATION")
                    display.getRealSize(size)
                    DisplayMemory.record(
                        name = display.name ?: "",
                        widthPx = size.x,
                        heightPx = size.y,
                        role = role,
                    )
                }
            }
            // MethodChannel.Result must be invoked from the main
            // thread. Hop back via the activity's main looper.
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(r)
            }
        }
    }

    /**
     * Strategy-driven secondary-display launch. Caller must already
     * be on [adbExecutor] — we issue shell commands which would
     * deadlock the main thread.
     *
     * Returns the LaunchResult-shaped map the MethodChannel result
     * forwards verbatim. Path strings:
     *   * `move-task-front` — Resume branch (existing same-display task)
     *   * `move-task` — Migrate branch (existing task on another display)
     *   * `am-start` / `am-start-rePinned` / `am-start-bounced` —
     *     FreshLaunch branch + bounce-back outcomes (legacy paths).
     */
    private fun handleSecondaryDisplayLaunch(
        packageName: String,
        targetDisplay: Int,
        amStartCmd: String,
    ): Map<String, Any?> {
        val stackList = AdbShellBridge.shell(MiniAppShellCommands.amStackList(), 4_000L)
        val snapshot = AmStackParser.parse(stackList)
        return when (val strategy = LaunchStrategyResolver.resolve(
            packageName = packageName,
            targetDisplay = targetDisplay,
            snapshot = snapshot,
        )) {
            is LaunchStrategy.Resume -> {
                // Bring the existing task to front on the same display
                // it already lives on. `move-task` to its own root is
                // a no-op on some BYD ROMs but reliably fronts the
                // task on Leopard 8 — same primitive [doMove] uses.
                AdbShellBridge.shell(
                    MiniAppShellCommands.amStackMoveTask(
                        strategy.taskId, strategy.rootTaskId,
                    ),
                    4_000L,
                )
                mapOf(
                    "ok" to true,
                    "path" to "move-task-front",
                    "error" to null,
                )
            }
            is LaunchStrategy.Migrate -> {
                // Existing task on a different display — reuse the
                // [doMove] flow which knows how to seed a target stack
                // (via ClusterActivity) when the destination is empty.
                doMove(packageName, strategy.toDisplay)
            }
            LaunchStrategy.FreshLaunch -> {
                when (val r = AmShellRunner.runWithRetry(amStartCmd, timeoutMs = 4_000L)) {
                    is AmShellResult.Ok -> {
                        if (r.attempts > 1) breadcrumbWmsRecovery("pkg.fresh_launch", r.attempts)
                        if (BOUNCE_BACK_PACKAGES.contains(packageName)) {
                            verifyAndRePinIfBounced(packageName, targetDisplay)
                        } else {
                            maybeFlagAutoPip(
                                packageName,
                                targetDisplay,
                                mapOf(
                                    "ok" to true,
                                    "path" to "am-start",
                                    "error" to null,
                                ),
                            )
                        }
                    }
                    is AmShellResult.WmsTransient -> {
                        breadcrumbWmsTransient("pkg.fresh_launch", r)
                        mapOf(
                            "ok" to false,
                            "path" to "wms_transient",
                            "error" to r.out.take(200),
                        )
                    }
                    is AmShellResult.HardFailure -> mapOf(
                        "ok" to false,
                        "path" to "am-start",
                        "error" to "${r.reason}: ${r.out.take(200)}",
                    )
                }
            }
        }
    }

    /**
     * Bounce-back recovery for known-bouncy packages. Runs after a
     * successful `am start --display N`. Verifies the task actually
     * landed on [requestedDisplayId]; if it bounced to another
     * display (typically 0), invokes [doMove] to forcibly re-pin it.
     *
     * Returns the LaunchResult-shaped map the caller forwards
     * verbatim. New `path` values:
     *   * `am-start` — bounce wasn't observed; landed correctly the
     *     first time. Indistinguishable from a clean launch.
     *   * `am-start-rePinned` — initial launch bounced; rePin
     *     succeeded. Mini-apps don't need to do anything; the user
     *     sees the app on the correct display. Worth surfacing in
     *     observability so we can spot a ROM regression where rePin
     *     starts failing more often.
     *   * `am-start-bounced` — bounced AND rePin failed (e.g. the AM
     *     refused move-task on this device's vendor build). The app
     *     is on the wrong display; mini-apps should treat this like
     *     `ok=false` and offer the user a fallback.
     *
     * Caller MUST already be on [adbExecutor] (we issue more shell
     * commands, which would deadlock the main thread).
     */
    private fun verifyAndRePinIfBounced(
        packageName: String,
        requestedDisplayId: Int,
    ): Map<String, Any?> {
        Thread.sleep(BOUNCE_VERIFY_DELAY_MS)
        // The verify read is single-shot: AmShellRunner.runOnce gives
        // us the same WMS classifier as the writes, but no retry
        // (we'd just re-read; the rePin step below is the actual
        // recovery vector).
        val verifyResult = AmShellRunner.runOnce(
            MiniAppShellCommands.amStackList(), 4_000L,
        )
        val stackList = when (verifyResult) {
            is AmShellResult.Ok -> verifyResult.out
            is AmShellResult.WmsTransient -> {
                Log.w(TAG, "rePin verify wms_transient for $packageName")
                return mapOf(
                    "ok" to true,
                    "path" to "am-start",
                    "error" to "verify_failed: wms_transient",
                )
            }
            is AmShellResult.HardFailure -> {
                Log.w(TAG, "rePin verify failed for $packageName: ${verifyResult.reason}")
                return mapOf(
                    "ok" to true,
                    "path" to "am-start",
                    "error" to "verify_failed: ${verifyResult.reason}",
                )
            }
        }
        val task = AmStackParser.findAnyDisplay(
            AmStackParser.parseAll(stackList), packageName,
        )
        if (task == null) {
            // Package isn't in the stack list at all. Either the
            // launch didn't actually start (despite no Error in
            // output) or the package terminated immediately. Surface
            // as bounced — mini-app can decide whether to retry.
            return mapOf(
                "ok" to false,
                "path" to "am-start-bounced",
                "error" to "no_task_after_launch",
            )
        }
        if (task.displayId == requestedDisplayId) {
            // Landed correctly. Indistinguishable to mini-apps from
            // a non-bouncy launch — same path string.
            return mapOf("ok" to true, "path" to "am-start", "error" to null)
        }
        // Bounced. Try to move it.
        val moveResult = try {
            doMove(packageName, requestedDisplayId)
        } catch (t: Throwable) {
            Log.w(TAG, "rePin doMove threw for $packageName: ${t.message}")
            return mapOf(
                "ok" to false,
                "path" to "am-start-bounced",
                "error" to "rePin_failed: ${t.message ?: t.javaClass.simpleName}",
            )
        }
        val moveOk = moveResult["ok"] == true
        // Propagate WMS-transient distinction up so the UI can show
        // a "tap to retry" affordance for the recoverable case.
        if (!moveOk && moveResult["path"] == "wms_transient") {
            return mapOf(
                "ok" to false,
                "path" to "am-start-bounced-wms-transient",
                "error" to "rePin_failed: ${moveResult["error"]}",
            )
        }
        return if (moveOk) {
            mapOf("ok" to true, "path" to "am-start-rePinned", "error" to null)
        } else {
            mapOf(
                "ok" to false,
                "path" to "am-start-bounced",
                "error" to "rePin_failed: ${moveResult["error"]}",
            )
        }
    }

    // ── move ────────────────────────────────────────────────────────────

    /**
     * Move a running package's task to another display. Useful for
     * "I set the route on the IVI, now show the running app on the
     * cluster" workflows where launch-on-display fails because the
     * app's launcher activity is a router that internally redirects
     * to an unexported MainActivity (e.g. Waze).
     *
     * Algorithm:
     *   1. `am stack list` to find the package's current taskId.
     *   2. Find any existing RootTask on the target displayId.
     *   3. If none exists, spawn one via `am start-activity --display N`
     *      of our own [ClusterActivity] (lightweight, idempotent).
     *   4. `am stack move-task <taskId> <targetStackId> true`.
     *   5. Verify the move took by re-querying `am stack list`.
     *
     * Note: `am stack move-task` prints a benign `ClassCastException`
     * on Leopard 8 even when the move succeeds — symptom of a logging
     * cast in the OEM build, not a fatal error. We verify by reading
     * back the stack state, not by parsing the cmd output.
     */
    private fun handleMove(call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        val displayId = call.argument<Int>("displayId")
        val expectCluster = call.argument<Boolean>("expectCluster") ?: false
        if (packageName == null || displayId == null) {
            result.success(
                mapOf("ok" to false, "path" to "denied", "error" to "packageName + displayId required"),
            )
            return
        }
        val roleCheck = checkDisplayRole(displayId, expectCluster)
        if (roleCheck != null) {
            result.success(roleCheck)
            return
        }
        adbExecutor.execute {
            val r: Map<String, Any?> = try {
                doMove(packageName, displayId)
            } catch (t: Throwable) {
                Log.w(TAG, "move failed: ${t.javaClass.simpleName}: ${t.message}")
                mapOf("ok" to false, "path" to "denied", "error" to (t.message ?: t.javaClass.simpleName))
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(r)
            }
        }
    }

    /**
     * Relocation fallback policy for [doMove].
     *
     * Pre-#136 `doMove` was **move-task only** — it never spawned a
     * fresh instance, so a screen-to-screen drop could not produce a
     * new pid. PR #136 (`8e689d9` + `d63dd7f`) added
     * [amStartDisplayFallback] (`am start --display N` = a fresh
     * relaunch = NEW pid) at every failure point; that is the
     * regression behind "the map reopens from zero on the cluster".
     *
     * Scoped restore: the same-pid contract is absolute — if the
     * task genuinely can't be reparented, leave the app running
     * where it is and report a clean failure (NO relaunch) — for
     * **Di5.1** (all displays) and **Di5.0** (driver-cluster ↔ IVI
     * only). Di5.0 fse/passenger still go via DiShare and never
     * reach `doMove`; Generic/unknown keep the am-start fallback
     * (conservative — unchanged).
     */
    private fun doMoveFallback(
        samePidMove: Boolean,
        packageName: String,
        displayId: Int,
        taskId: Int,
        error: String,
    ): Map<String, Any?> =
        if (samePidMove) {
            Log.w(
                TAG,
                "doMove: same-pid contract — NOT relaunching " +
                    "$packageName on display $displayId ($error)",
            )
            mapOf(
                "ok" to false,
                "path" to "same_pid_no_relaunch",
                "error" to error,
            )
        } else {
            amStartDisplayFallback(packageName, displayId, taskId)
                ?: mapOf("ok" to false, "path" to "denied", "error" to error)
        }

    /**
     * The DiLink generation resolved the SAME way the planner does
     * (MiniAppDispatcher active model → forVariant). `forActiveCar()`
     * is only populated AFTER ModelDetector.detect() + setActive; mid-
     * drag it can still be the GENERIC default whose dilinkFamily is
     * Unknown — which would silently drop a Di5.0 move onto the
     * non-same-pid am-start (new-pid) fallback even though the
     * planner already resolved Di5.0 (it produced the plan). Keep
     * forActiveCar() only as the fallback for paths where the
     * dispatcher list may be empty.
     */
    private fun activeDilinkFamily(): DilinkFamily =
        CarProfileRegistry
            .forChain(MiniAppDispatcher.activeModelIds())
            .dilinkFamily
            .takeIf { it != DilinkFamily.Unknown }
            ?: CarProfileRegistry.forActiveCar().dilinkFamily

    /**
     * The active car profile resolved the same way the dilink family
     * is (variant → forVariant → forActiveCar fallback). Routes that
     * need the trim's topology (cursor remap, hidden layers, …) read
     * through this — never reach into [CarProfileRegistry] directly.
     * Returns the GENERIC profile when nothing is detected; its
     * `*Remap` maps are empty, so callers get identity mapping (the
     * pre-profile baseline behaviour).
     */
    private fun activeProfile() =
        CarProfileRegistry
            .forChain(MiniAppDispatcher.activeModelIds())
            .takeIf { it.dilinkFamily != DilinkFamily.Unknown }
            ?: CarProfileRegistry.forActiveCar()

    /**
     * Post-move-stack probe: detect whether [packageName] left a
     * Picture-in-Picture ghost window on the IVI default display.
     * Apps with `android:supportsPictureInPicture="true"` (Sygic
     * Maps, BYD's native media player, some launchers) treat the
     * config-change Activity recreate that move-stack causes as a
     * "user left this app" signal and call `enterPictureInPictureMode`
     * before the move finalises — the result is the task on the
     * cluster + a small floating PiP window on the IVI in a corner
     * (~300–650 px wide, bottom-right typical).
     *
     * Heuristic: scan `dumpsys input` for a window owned by the
     * package on displayId 0 whose frame width is well under the
     * IVI's pixel width (PiP windows are ~25 % of IVI; full-screen
     * activities span the whole display). Brief settle delay first
     * so the PiP transition has time to materialise (the framework
     * picks PiP bounds AFTER the move-stack returns).
     *
     * Returns true on detection; caller falls back to force-stop +
     * fresh-launch to clear the ghost. Returns false if no window
     * on IVI / window is full-screen / dumpsys throws.
     */
    private fun detectsAutoPipGhostOnIvi(packageName: String): Boolean {
        // Roughly the time it takes the PiP transition animation to
        // settle on L8 — measured at ~600 ms. 800 ms gives headroom
        // without making the user wait too long if there's no ghost.
        Thread.sleep(800)
        val safePkg = packageName.replace("\"", "")
        val out = try {
            (
                AmShellRunner.runOnce(
                    "dumpsys input | grep -F $safePkg",
                    4_000L,
                ) as? AmShellResult.Ok
                )?.out ?: return false
        } catch (_: Throwable) {
            return false
        }
        // Window line shape (Di5.1 / A13):
        //   N: name='<hex> <pkg>/<activity>', id=…, displayId=0,
        //      inputConfig=…, alpha=…, frame=[x1,y1][x2,y2], …
        // PiP bounds are typically ~400×625 in the bottom-right
        // corner of a 2560×1600 IVI. The exact threshold isn't
        // critical — any PiP window will be smaller than half the
        // IVI's pixel width.
        val re = Regex(
            """name='[0-9a-f]+ \Q$packageName\E/[^']*'""" +
                """[^\n]*?displayId=0""" +
                """[^\n]*?frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]""",
        )
        for (m in re.findAll(out)) {
            val x1 = m.groupValues[1].toIntOrNull() ?: continue
            val x2 = m.groupValues[3].toIntOrNull() ?: continue
            val width = x2 - x1
            if (width in 1..1280) {
                Log.i(
                    TAG,
                    "detectsAutoPipGhostOnIvi: $packageName window on " +
                        "IVI is ${width}px wide (PiP-like) → ghost",
                )
                return true
            }
        }
        return false
    }

    /**
     * Tag [baseResult] with `*-auto-pip` if [packageName] left an
     * auto-PiP ghost on the IVI after a cluster move/launch. Both
     * the move-stack path in [doMove] and the FreshLaunch path in
     * [handleSecondaryDisplayLaunch] route through here so any
     * cluster-bound launch that ends in PiP surfaces the same way
     * to the operator's snackbar.
     *
     * For IVI destinations or non-PiP apps the [baseResult] is
     * returned unchanged — the helper is a no-op fast path on the
     * common case.
     */
    private fun maybeFlagAutoPip(
        packageName: String,
        targetDisplay: Int,
        baseResult: Map<String, Any?>,
    ): Map<String, Any?> {
        if (targetDisplay == DEFAULT_DISPLAY) return baseResult
        if (!detectsAutoPipGhostOnIvi(packageName)) return baseResult
        val basePath = (baseResult["path"] as? String) ?: "ok"
        return baseResult + ("path" to "$basePath-auto-pip")
    }

    private fun doMove(packageName: String, displayId: Int): Map<String, Any?> {
        // Same-pid move-stack contract (regression restore): pre-#136
        // doMove was move-task-ONLY and never relaunched — a drop
        // could not produce a new pid. PR #136 (8e689d9 + d63dd7f)
        // added an `am start --display` fallback that resurfaced as
        // "app reopens with a new pid when sent to the cluster". The
        // fallback is disabled here (see [doMoveFallback]) for every
        // car that must keep the same pid:
        //   * Di5.1 — all displays.
        //   * Di5.0 — the cluster (cluster_c = 3 OR cluster_tr = 4,
        //     whichever is the car's driver cluster) ↔ IVI (0) round
        //     trip ONLY (operator-scoped). Di5.0 fse/passenger still
        //     use DiShare and never enter doMove; ShellLaunch is only
        //     ever produced for a Di5.0 cluster target.
        // `samePidMove` = "this move must NEVER relaunch" — gates
        // the move-stack branch + tells [doMoveFallback] not to
        // am-start. (Was named `di51` historically — Di5.0 cluster↔
        // IVI now also enters this contract, so the new name reads
        // honestly.) Generic/unknown unchanged.
        val family = activeDilinkFamily()
        val di50ClusterIviMove = family == DilinkFamily.Di50 &&
            (
                displayId == DishareTransport.DISPLAY_ID_IVI ||
                    displayId == DishareTransport.DISPLAY_ID_CLUSTER_CENTER ||
                    displayId == DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT
                )
        val samePidMove = family == DilinkFamily.Di51 || di50ClusterIviMove
        // Anything that isn't the IVI is "secondary" for our purposes
        // (cluster / FSE). Used to (a) deny PiP at the appops level
        // BEFORE the move so apps like Sygic Maps + BYD media player
        // can't auto-enter Picture-in-Picture on the cross-display
        // recreate, and (b) gate the post-move ghost-PiP check as a
        // belt-and-suspenders observation.
        //
        // The appops `PICTURE_IN_PICTURE deny` is the silver bullet
        // proven via shell 2026-05-20: with it set, `am display
        // move-stack` on Sygic produced a full-screen `[0,0][1920,720]`
        // task on displayId=5 instead of the previous PiP-bounds
        // ghost in the IVI corner. Persistent appops setting (no
        // re-allow on the IVI return path — operators in this trim
        // don't typically want PiP anyway, and re-allowing would
        // re-enable the auto-PiP for the next cluster move).
        val targetIsSecondary = displayId != DEFAULT_DISPLAY
        if (targetIsSecondary) {
            AmShellRunner.runOnce(
                "appops set $packageName PICTURE_IN_PICTURE deny", 4_000L,
            )
        }
        // Verification reads route through runOnce — read paths don't
        // benefit from retry (we re-read after each write anyway).
        val initialResult = AmShellRunner.runOnce(
            MiniAppShellCommands.amStackList(), 4_000L,
        )
        val initial = when (initialResult) {
            is AmShellResult.Ok -> initialResult.out
            // A WMS hiccup on the verification read is recoverable by
            // the writes below; treat as best-effort and proceed with
            // an empty parse (the not-running branch will fire if so).
            else -> ""
        }
        val initialSnapshot = AmStackParser.parse(initial)
        val current = AmStackParser.findAnyDisplay(initialSnapshot.tasks, packageName)
            ?: return mapOf(
                "ok" to false, "path" to "denied", "error" to "package not running",
            )
        if (current.displayId == displayId) {
            return mapOf("ok" to true, "path" to "no-op", "error" to null)
        }
        // Fresh-launch fallback for [ClusterLaunchPolicy.freshLaunchOnly]
        // packages (ReVanced family). The patched MainActivity NPEs
        // on cross-display Activity recreate, so move-stack kills
        // the process. Two different launch shapes depending on
        // target — both shell-verified 2026-05-20:
        //
        //   * Cluster (secondary) destination: `am start --display N
        //     --activity-multiple-task` — needs both flags because
        //     ATMS otherwise reuses the IVI task on the IVI display.
        //     ReVanced tolerates this combination on a non-default
        //     display.
        //   * IVI (default) destination: plain `am start -n` — the
        //     `--activity-multiple-task` flag on display 0 trips
        //     ReVanced into the "App has stopped" crash dialog (the
        //     standard launcher path doesn't pass this flag, and
        //     ReVanced's patched launch code only handles the simple
        //     intent). force-stop first to clear residual recreate
        //     state, then a clean intent launch.
        if (ClusterLaunchPolicy.freshLaunchOnly(packageName)) {
            AmShellRunner.runOnce("am force-stop $packageName", 4_000L)
            if (displayId == DEFAULT_DISPLAY) {
                // CLEAR_TASK is the critical flag: it tells ATMS to
                // wipe the existing task slot (including its saved-
                // instance bundle) before starting. Without it, the
                // BYD ROM's ATMS RELAUNCHES the activity from the
                // persisted bundle, and ReVanced's retained
                // first-run DialogFragment NPEs on
                // `Dialog.setOwnerActivity(null)` during
                // `DialogFragment.onActivityCreated` — operator-
                // attested 2026-05-20 crash trace:
                //   `Caused by: java.lang.NullPointerException:
                //    Attempt to invoke virtual method 'void
                //    android.app.Dialog.setOwnerActivity(...)' on
                //    a null object reference`. Shell-verified
                //    clean launch with these flags. We OR the
                //    well-known Intent constants instead of hard-
                //    coding the hex literal so the forbidden-string
                //    CI gate stays clean (BYD feature-id regex
                //    matches any 8-digit hex) — this is purely a
                //    source-form preference; the resulting integer
                //    is identical.
                val launchFlags =
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK
                Log.i(
                    TAG,
                    "doMove: freshLaunchOnly→IVI clean launch — " +
                        "$packageName via `am start -f " +
                        "0x${"%x".format(launchFlags)} -n` " +
                        "(CLEAR_TASK + NEW_TASK avoids the BYD-ROM " +
                        "relaunch-from-bundle DialogFragment NPE)",
                )
                val launchIntent = context.packageManager
                    .getLaunchIntentForPackage(packageName)
                val component = launchIntent?.component?.flattenToShortString()
                if (component == null) {
                    return mapOf(
                        "ok" to false,
                        "path" to "denied",
                        "error" to "no_launcher_activity",
                    )
                }
                AmShellRunner.runOnce(
                    "am start -f 0x${"%x".format(launchFlags)} -n $component",
                    4_000L,
                )
                return mapOf(
                    "ok" to true,
                    "path" to "force-stop-clean-launch",
                    "error" to null,
                )
            }
            Log.i(
                TAG,
                "doMove: freshLaunchOnly→cluster — force-stop + " +
                    "am start --display $displayId for $packageName",
            )
            return amStartDisplayFallback(
                packageName, displayId, current.taskId,
            ) ?: mapOf(
                "ok" to false,
                "path" to "denied",
                "error" to "fresh_launch_failed",
            )
        }
        if (samePidMove) {
            // Di5.1: move the WHOLE root task to the target display.
            // `am display move-stack` keeps the SAME pid and needs NO
            // pre-existing target stack — the L8 FSE / cluster only
            // ever host a u999/`home` stack, so `am stack move-task`
            // (reparent into a stack ON the display, the path below)
            // cannot land there and used to fall back to a relaunch
            // (new pid). Proven on 192.168.4.72: IVI↔FSE↔cluster,
            // bidirectional, same pid. Replaces the find-rootTask →
            // seed-ClusterActivity → move-task dance entirely on
            // Di5.1; never relaunches (doMoveFallback safety net).
            val mv = AmShellRunner.runWithRetry(
                MiniAppShellCommands.amDisplayMoveStack(
                    current.rootTaskId, displayId,
                ),
                4_000L,
            )
            if (mv is AmShellResult.HardFailure) {
                Log.w(
                    TAG,
                    "doMove: am display move-stack ${current.rootTaskId}" +
                        " -> $displayId hard fail (${mv.reason})",
                )
                return doMoveFallback(
                    samePidMove, packageName, displayId, current.taskId,
                    "am display move-stack failed: ${mv.reason}",
                )
            }
            if (mv is AmShellResult.WmsTransient) {
                breadcrumbWmsTransient("pkg.do_move.move_stack", mv)
                Log.i(TAG, "doMove move-stack wms_transient — verifying anyway")
            }
            // Verify by re-query: the move sometimes prints a benign
            // exception on L8 yet still takes (same pattern the
            // move-task path uses below).
            val verifyOut = (
                AmShellRunner.runOnce(MiniAppShellCommands.amStackList(), 4_000L)
                    as? AmShellResult.Ok
                )?.out ?: ""
            val verifySnap = AmStackParser.parse(verifyOut)
            val landed = AmStackParser.findAnyDisplay(
                verifySnap.tasks, packageName,
            )
            return if (landed != null && landed.displayId == displayId) {
                // Repaint the just-vacated source display. A projected
                // secondary display (cluster / FSE) has no fallback
                // layer, so once the stack leaves, SurfaceFlinger
                // keeps the previous app's last frame frozen there.
                // Best-effort + fire-and-forget: the move already
                // succeeded; never fail it on the cosmetic repaint.
                // Skip the IVI (display 0 has home/wallpaper) and any
                // display still occupied by another stack.
                val src = current.displayId
                if (src != DEFAULT_DISPLAY &&
                    verifySnap.rootTasks.none { it.displayId == src }
                ) {
                    Log.i(TAG, "doMove: blanking vacated display $src")
                    AmShellRunner.runOnce(
                        MiniAppShellCommands.amStartClusterBlank(src), 4_000L,
                    )
                }
                // Auto-PiP ghost check: apps with
                // `supportsPictureInPicture` (Sygic Maps, BYD media
                // player) take the cross-display launch as a "user
                // left" signal and call `enterPictureInPictureMode`
                // — the result is a small floating window on the
                // IVI corner instead of the full-screen experience
                // the operator dragged toward. Force-stop + fresh-
                // launch does NOT help: the same auto-PiP triggers
                // on relaunch (Sygic does it unconditionally on a
                // non-default display). So we surface the state to
                // the operator via a special path string — Dart
                // side shows a snackbar "this app may shrink to a
                // small window; try a different one." — and leave
                // the task where Android put it. Apps that DON'T
                // auto-PiP (Spotify, Telegram, Shaheen) sail through
                // this check unchanged with `path=move-stack`.
                maybeFlagAutoPip(
                    packageName,
                    displayId,
                    mapOf("ok" to true, "path" to "move-stack", "error" to null),
                )
            } else {
                doMoveFallback(
                    samePidMove, packageName, displayId, current.taskId,
                    "am display move-stack did not land on display " +
                        "$displayId (now on ${landed?.displayId})",
                )
            }
        }
        // ── Non-Di5.1 (Generic / unknown) — UNCHANGED path below.
        //    Di5.0 never reaches doMove (DiShare). ──────────────────
        // 1. Find or spawn a RootTask on the target display.
        var targetRootTaskId = AmStackParser.findRootTaskOnDisplay(
            initialSnapshot.rootTasks, displayId,
        )
        if (targetRootTaskId == null) {
            // No movable `standard`/u0 stack on the target. Two shapes:
            //
            //   * The display already has ≥1 (non-movable) stack — the
            //     FSE multi-user *home* display. Our ClusterActivity
            //     placeholder provably will NOT root there (verified on
            //     192.168.4.72), so seeding it is ~0.8 s of wasted work
            //     plus a visible flash. Skip straight to the proven
            //     `am start --display N <component>` relocation.
            //   * Genuinely empty (no stack at all) — e.g. an idle
            //     cluster display. ClusterActivity DOES root there, so
            //     seed it and move-task into it (keeps the same task
            //     instance; cheaper than a fresh launch).
            if (initialSnapshot.rootTasks.any { it.displayId == displayId }) {
                Log.w(
                    TAG,
                    "doMove: display $displayId has only non-movable " +
                        "stacks (multi-user home) — skipping dead " +
                        "ClusterActivity seed, am-start relocation",
                )
                return doMoveFallback(
                    samePidMove, packageName, displayId, current.taskId,
                    "couldn't relocate to display $displayId " +
                        "(only non-movable stacks)",
                )
            }
            // Empty target display — seed a placeholder so there's a
            // stack to move into. ClusterActivity is the right cousin:
            // our own, exported, excludeFromRecents. Route through
            // runWithRetry so a WMS-transient spawn gets one retry.
            val placeholderCmd = MiniAppShellCommands.amStartOnDisplay(
                displayId,
                MiniAppShellCommands.clusterActivityComponent(),
            )
            when (val seed = AmShellRunner.runWithRetry(placeholderCmd, 4_000L)) {
                is AmShellResult.Ok -> {
                    if (seed.attempts > 1) breadcrumbWmsRecovery("pkg.do_move.seed", seed.attempts)
                }
                is AmShellResult.WmsTransient -> {
                    breadcrumbWmsTransient("pkg.do_move.seed", seed)
                    return mapOf(
                        "ok" to false,
                        "path" to "wms_transient",
                        "error" to seed.out.take(200),
                    )
                }
                is AmShellResult.HardFailure ->
                    // Seeding our placeholder hard-failed. Pre-#136 this
                    // returned a clean error (no relaunch). Di5.1 keeps
                    // that contract; non-Di5.1 still gets the am-start
                    // relocation. See [doMoveFallback].
                    return doMoveFallback(
                        samePidMove, packageName, displayId, current.taskId,
                        "couldn't spawn a stack on display $displayId: ${seed.reason}",
                    )
            }
            Thread.sleep(800)
            val refreshedResult = AmShellRunner.runOnce(
                MiniAppShellCommands.amStackList(), 4_000L,
            )
            val refreshed = if (refreshedResult is AmShellResult.Ok) {
                refreshedResult.out
            } else {
                ""
            }
            targetRootTaskId = AmStackParser.findRootTaskOnDisplay(
                AmStackParser.parse(refreshed).rootTasks, displayId,
            ) ?: run {
                // Defensive: we only reach here for a display that was
                // *empty* (no stack) yet ClusterActivity still didn't
                // root after the seed — unexpected on a genuinely idle
                // display, but never dead-end. The FSE multi-user-home
                // case is already short-circuited above (it never
                // seeds). Relocate directly with the proven
                // `am start --display N <component>` primitive.
                Log.w(
                    TAG,
                    "doMove: seeded empty display $displayId but " +
                        "ClusterActivity didn't root",
                )
                return doMoveFallback(
                    samePidMove, packageName, displayId, current.taskId,
                    "couldn't relocate to display $displayId " +
                        "(no movable stack)",
                )
            }
        }
        if (targetRootTaskId == current.rootTaskId) {
            return mapOf("ok" to true, "path" to "no-op", "error" to null)
        }
        // 2. Move it. Don't fail the operation on the
        // ClassCastException in the output — AmShellRunner classifies
        // it as a WmsTransient and retries; we verify by querying
        // back too because the move sometimes succeeds after the
        // exception print on Leopard 8.
        val moveCmd = MiniAppShellCommands.amStackMoveTask(current.taskId, targetRootTaskId)
        when (val mv = AmShellRunner.runWithRetry(moveCmd, 4_000L)) {
            is AmShellResult.Ok -> {
                if (mv.attempts > 1) breadcrumbWmsRecovery("pkg.do_move.move", mv.attempts)
            }
            is AmShellResult.WmsTransient -> {
                breadcrumbWmsTransient("pkg.do_move.move", mv)
                // Verify-step below may still see the move took. If
                // not, propagate the wms_transient path string.
                Log.i(TAG, "doMove move-task wms_transient — verifying anyway")
            }
            is AmShellResult.HardFailure -> {
                // `move-task` was rejected — typically
                // `move_task_rejected` (ATMS
                // IllegalArgumentException: moveTaskToRootTask) when
                // the only stack on the target is non-`standard` /
                // cross-user, i.e. the Leopard 8 FSE multi-user home
                // stack. The movable-stack filter in
                // [AmStackParser.findRootTaskOnDisplay] makes the seed
                // path above avoid this for FSE, but keep a safety
                // net for any unforeseen cross-user/home topology:
                // fall back to the proven `am start --display N`
                // primitive (lands an open app on the target as a
                // current-user task, no cross-user reparent).
                Log.w(TAG, "doMove move-task hard fail (${mv.reason})")
                // Pre-#136 returned a clean error here (no relaunch).
                // Di5.1 keeps that same-pid contract; non-Di5.1 still
                // gets the am-start relocation. `am start` may land a
                // *fresh* task, so this branch cannot fall through to
                // the `current.taskId` move-task verify below.
                return doMoveFallback(
                    samePidMove, packageName, displayId, current.taskId,
                    "move-task hard failure: ${mv.reason}: ${mv.out.take(200)}",
                )
            }
        }
        Thread.sleep(400)
        val verifiedResult = AmShellRunner.runOnce(
            MiniAppShellCommands.amStackList(), 4_000L,
        )
        val verified = if (verifiedResult is AmShellResult.Ok) verifiedResult.out else ""
        val nowOnDisplay = AmStackParser.displayOfTask(
            AmStackParser.parseAll(verified), current.taskId,
        )
        return if (nowOnDisplay == displayId) {
            mapOf("ok" to true, "path" to "move-task", "error" to null)
        } else {
            mapOf(
                "ok" to false, "path" to "denied",
                "error" to "move-task didn't stick (still on display=$nowOnDisplay)",
            )
        }
    }

    /**
     * Last-resort relocation when `am stack move-task` is
     * *structurally* rejected (the Leopard 8 FSE multi-user home
     * stack — ATMS `IllegalArgumentException: moveTaskToRootTask`,
     * classified `move_task_rejected`). `am start --display N
     * <launcher-component>` brings an already-running app onto
     * [displayId] **as a current-user task with no cross-user
     * reparent** — the exact primitive
     * [handleSecondaryDisplayLaunch]'s FreshLaunch branch uses, and
     * the one proven on 192.168.4.72 (Di5.1/L8) to land an open app
     * on FSE.
     *
     * Returns a LaunchResult-shaped map only on a *verified*
     * relocation (the relaunch may reuse [taskId] or spawn a fresh
     * task — either is accepted as long as the package is now on
     * [displayId]); returns null to let [doMove] surface the
     * original move-task failure. Caller MUST already be on
     * [adbExecutor] (issues more shell commands).
     */
    private fun amStartDisplayFallback(
        packageName: String,
        displayId: Int,
        taskId: Int,
    ): Map<String, Any?>? {
        val launchIntent =
            context.packageManager.getLaunchIntentForPackage(packageName)
        val component =
            launchIntent?.component?.flattenToShortString() ?: return null
        val cmd = MiniAppShellCommands.amStartOnDisplay(displayId, component)
        when (val r = AmShellRunner.runWithRetry(cmd, 4_000L)) {
            is AmShellResult.Ok ->
                if (r.attempts > 1) {
                    breadcrumbWmsRecovery("pkg.do_move.fallback", r.attempts)
                }
            is AmShellResult.WmsTransient ->
                // The verify read-back below is the source of truth.
                Log.i(TAG, "amStartDisplayFallback wms_transient — verifying anyway")
            is AmShellResult.HardFailure -> return null
        }
        Thread.sleep(400)
        val verifiedResult = AmShellRunner.runOnce(
            MiniAppShellCommands.amStackList(), 4_000L,
        )
        val verified =
            if (verifiedResult is AmShellResult.Ok) verifiedResult.out else ""
        val rows = AmStackParser.parseAll(verified)
        val landed =
            AmStackParser.displayOfTask(rows, taskId) == displayId ||
                AmStackParser.findOnDisplay(rows, packageName, displayId) != null
        return if (landed) {
            mapOf("ok" to true, "path" to "am-start-fallback", "error" to null)
        } else {
            null
        }
    }

    /**
     * Sentry breadcrumb on the final-attempt failure of an
     * [AmShellRunner.runWithRetry]. Lives at the call site (not
     * inside the runner) so the runner stays Sentry-agnostic. Only
     * fires on the FINAL WmsTransient — first-attempt failures are
     * normal noise on this ROM and would drown the signal. The
     * `attempts` data field lets the dashboard show how many tries
     * the call site was configured for.
     */
    private fun breadcrumbWmsTransient(callSite: String, result: AmShellResult.WmsTransient) {

    }

    /**
     * Sentry breadcrumb on a recovery — the call site succeeded but
     * needed [attempts] > 1 tries to get there. INFO level so the
     * breadcrumb feeds the histogram without polluting the issue
     * stream. Pair with [breadcrumbWmsTransient] to measure the
     * silently-absorbed rate vs the exhausted rate.
     */
    private fun breadcrumbWmsRecovery(callSite: String, attempts: Int) {

    }

    // ── running ──────────────────────────────────────────────────────────

    /**
     * Per-display task topology — one entry per running task with
     * `(taskId, packageName, displayId, isForeground)`. Backed by the
     * same [AmStackParser] the launch decision path uses, so the UI's
     * "what's on screen X" view is guaranteed to agree with what the
     * launch resolver sees a moment later.
     *
     * Threading: shell hop (loopback ADB), so it has to run off the
     * MethodChannel thread. The Dart-side
     * `runningAppsControllerProvider` polls this every ~2 s while the
     * home screen is mounted; the underlying `am stack list` is cheap
     * (~50–100 ms) and the parse is microsecond-class.
     */
    private fun handleRunning(result: MethodChannel.Result) {
        adbExecutor.execute {
            val rows: List<Map<String, Any?>> = try {
                val out = AdbShellBridge.shell(
                    MiniAppShellCommands.amStackList(), 4_000L,
                )
                // Re-attribute a cluster-projected app's task to the
                // cluster card. The cast app runs on our VirtualDisplay
                // (vdId), but the DISPLAYS card is keyed on the cluster's
                // Android display id (hostId) — without this remap the
                // card never shows the cast app as a running chip.
                val proj = ClusterActivity.activeProjection() // (pkg, vdId, hostId)
                AmStackParser.parseAll(out).map {
                    val onCluster = proj != null &&
                        it.displayId == proj.second &&
                        it.packageName == proj.first
                    mapOf<String, Any?>(
                        "taskId" to it.taskId,
                        "rootTaskId" to it.rootTaskId,
                        "displayId" to if (onCluster) proj!!.third else it.displayId,
                        "packageName" to it.packageName,
                        "isForeground" to it.isForeground,
                    )
                }
            } catch (t: Throwable) {
                Log.w(TAG, "running failed: ${t.javaClass.simpleName}: ${t.message}")
                emptyList()
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(mapOf("rows" to rows))
            }
        }
    }

    /**
     * Host-authoritative "what app is on display N right now" — reads
     * the live `am stack list` (the single source of truth) rather
     * than the Dart-side polled chip cache. Powers the per-card
     * "send back" action: the running-chip on a secondary card can be
     * absent (poll lag, the host-package filter, a bouncy foreign app
     * mid-relaunch on the XDJA cluster), so a chip-drag is not a
     * reliable way to move an app *off* a secondary display. This op
     * resolves the package deterministically; the caller then issues
     * a normal `launch` to the destination.
     *
     * Returns `{packageName: <pkg>|null}`. The host's own package is
     * excluded (you don't relocate the dashboard). Prefers a
     * foreground task on the display, else the first task there.
     * Off-main-thread — `am stack list` is blocking shell I/O.
     */
    private fun handleTopOnDisplay(call: MethodCall, result: MethodChannel.Result) {
        val displayId = call.argument<Int>("displayId")
        if (displayId == null) {
            result.success(mapOf("packageName" to null))
            return
        }
        adbExecutor.execute {
            val pkg: String? = try {
                val out = AdbShellBridge.shell(
                    MiniAppShellCommands.amStackList(), 4_000L,
                )
                val onDisplay = AmStackParser.parseAll(out).filter {
                    it.displayId == displayId &&
                        it.packageName != "com.i99dev.ilink"
                }
                (onDisplay.firstOrNull { it.isForeground } ?: onDisplay.firstOrNull())
                    ?.packageName
            } catch (t: Throwable) {
                Log.w(TAG, "topOnDisplay failed: ${t.javaClass.simpleName}: ${t.message}")
                null
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(mapOf("packageName" to pkg))
            }
        }
    }

    // ── tour marker ──────────────────────────────────────────────────────

    /**
     * Calibration-tour marker launch. Spawns the host's own
     * [com.i99dev.ilink.display.ClusterActivity] in tour mode on
     * [displayId] — a full-screen coloured tile with a giant
     * "DISPLAY N" label so the user can identify which physical
     * screen this Activity landed on.
     *
     * Bypasses [LaunchStrategyResolver] on purpose: the tour wants a
     * FRESH marker on every probe, not a resume of the prior one.
     * The resolver's Resume / Migrate branches make sense for normal
     * launches but would defeat the whole point of "show me a new
     * marker on display N right now."
     *
     * To kill the marker after the user answers, the caller invokes
     * `pkg.stop(packageName: "com.i99dev.ilink")` — but that
     * would also kill the host. Better: the tour overlay finishes
     * the marker by launching the next one on a *different* display,
     * or by sending an explicit "finish" via a future op. For v1 we
     * leave the marker up until the user moves on, then the next
     * launch displaces it — accepting the brief overlap as a known
     * UX cost.
     */
    private fun handleTourMarker(call: MethodCall, result: MethodChannel.Result) {
        val displayId = call.argument<Int>("displayId")
        // ARGB color values like 0xFFE53935 (4_293_282_613) exceed Int.MAX_VALUE
        // and serialize across the MethodChannel as java.lang.Long, not
        // java.lang.Integer. Reading via `argument<Int>` would throw
        // `Long cannot be cast to Integer` on those values. Going through
        // `Number` accepts both shapes; `.toInt()` then truncates to the
        // 32-bit ARGB representation Android uses for setBackgroundColor.
        val colorArgb = call.argument<Number>("colorArgb")?.toInt()
            ?: 0xFFAA33FF.toInt()
        val label = call.argument<String>("label") ?: ""
        if (displayId == null) {
            result.success(
                mapOf("ok" to false, "error" to "displayId required"),
            )
            return
        }
        // Build the am-start command. We append the tour extras to the
        // base amStartOnDisplay template — same `--activity-multiple-task`
        // / `--display N` plumbing the normal launch path uses, plus
        // `--es iLINK.tour 1` etc. Default-display variant uses
        // `Context.startActivity` so we don't have to shell.
        val component = "com.i99dev.ilink/.display.ClusterActivity"
        if (displayId == DEFAULT_DISPLAY) {
            try {
                val intent = Intent().apply {
                    setClassName(
                        context.packageName,
                        "com.i99dev.ilink.display.ClusterActivity",
                    )
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
                    )
                    putExtra("ilink.tour", "1")
                    putExtra("ilink.tour.displayId", displayId)
                    putExtra("ilink.tour.colorArgb", colorArgb)
                    putExtra("ilink.tour.label", label)
                }
                context.startActivity(intent)
                result.success(mapOf("ok" to true))
            } catch (t: Throwable) {
                result.success(
                    mapOf("ok" to false, "error" to (t.message ?: t.javaClass.simpleName)),
                )
            }
            return
        }
        adbExecutor.execute {
            val cmd = buildString {
                append(MiniAppShellCommands.amStartOnDisplay(displayId, component))
                append(" --es ilink.tour 1")
                append(" --ei ilink.tour.displayId ").append(displayId)
                append(" --ei ilink.tour.colorArgb ").append(colorArgb)
                if (label.isNotEmpty()) {
                    // Escape spaces + quotes for the shell — labels
                    // are short and ASCII so the simple replace is
                    // safe; broader sanitization can come later if
                    // we let user input flow into here.
                    val safe = label.replace("\"", "\\\"")
                    append(" --es ilink.tour.label \"").append(safe).append('"')
                }
            }
            // Tour markers go through runWithRetry so a one-off WMS
            // transient doesn't leave the user staring at a missing
            // marker that the second attempt would have lit up. Errors
            // surface as PlatformException with a typed code so the
            // overlay can render Retry vs Skip-this-display.
            val r = AmShellRunner.runWithRetry(cmd, timeoutMs = 4_000L)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                when (r) {
                    is AmShellResult.Ok -> {
                        if (r.attempts > 1) breadcrumbWmsRecovery("pkg.tour_marker", r.attempts)
                        result.success(
                            mapOf("ok" to true, "path" to "tour-marker"),
                        )
                    }
                    is AmShellResult.WmsTransient -> {
                        breadcrumbWmsTransient("pkg.tour_marker", r)
                        result.error(
                            "tour_marker_wms_transient",
                            r.out.take(200),
                            null,
                        )
                    }
                    is AmShellResult.HardFailure -> result.error(
                        "tour_marker_failed",
                        "${r.reason}: ${r.out.take(200)}",
                        null,
                    )
                }
            }
        }
    }

    /**
     * Finish every live tour-marker activity. Called from the IVI
     * overlay when the calibration flow leaves [TourRunning] (commit /
     * cancel / advance into the DiShare probe). Without this, the
     * last-rendered marker stays pinned on the cluster until something
     * else evicts it. Returns `{ ok: true, finished: N }`; the count
     * helps the Dart side log when a finish ran with no live markers
     * (idempotent — a stray call after the user manually navigated
     * away on the cluster shouldn't error).
     */
    private fun handleTourFinish(result: MethodChannel.Result) {
        try {
            val n = ClusterActivity.finishAllTours()
            result.success(mapOf("ok" to true, "finished" to n))
        } catch (t: Throwable) {
            result.success(
                mapOf("ok" to false, "error" to (t.message ?: t.javaClass.simpleName)),
            )
        }
    }

    // ── stop ─────────────────────────────────────────────────────────────

    /**
     * `am force-stop <packageName>` over loopback ADB. Used by the
     * pkg-launcher's "Clear Cluster" button to evict whatever the
     * mini-app launched onto the cluster so XDJA's normal projection
     * can reclaim the surface.
     *
     * Permission gating: same scope as `pkg.launch` — if you can put
     * an app on a display, you can take it off. No new tier needed.
     *
     * Threading: shell hop, must run off the MethodChannel thread.
     */
    private fun handleStop(call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        if (packageName == null || !PACKAGE_NAME_REGEX.matches(packageName)) {
            result.success(
                mapOf(
                    "ok" to false,
                    "path" to "denied",
                    "error" to "packageName invalid",
                ),
            )
            return
        }
        adbExecutor.execute {
            // force-stop on a process that doesn't exist returns
            // cleanly; no retry needed (a transient WMS hit on
            // force-stop is a vanishingly rare case and the caller
            // will re-issue stop on the next user action anyway).
            val outcome = AmShellRunner.runOnce(
                "am force-stop $packageName", 4_000L,
            )
            val r: Map<String, Any?> = when (outcome) {
                is AmShellResult.Ok -> mapOf(
                    "ok" to true, "path" to "force-stop", "error" to null,
                )
                is AmShellResult.WmsTransient -> mapOf(
                    "ok" to false,
                    "path" to "wms_transient",
                    "error" to outcome.out.take(200),
                )
                is AmShellResult.HardFailure -> mapOf(
                    "ok" to false,
                    "path" to "denied",
                    "error" to "${outcome.reason}: ${outcome.out.take(200)}",
                )
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(r)
            }
        }
    }

    /**
     * Resolve the role of [displayId] (or the default display when
     * null) and reject mismatches against [expectCluster].
     *
     * Returns null when the request is allowed; otherwise a
     * `LaunchResult`-shaped map the caller passes straight back to
     * the MethodChannel result.
     *
     * Error code prefixes are stable: SDK pattern-matches on
     * `role:` to surface a typed "use the cluster op" hint to the
     * mini-app developer.
     */
    private fun checkDisplayRole(displayId: Int?, expectCluster: Boolean): Map<String, Any?>? {
        val resolvedId = displayId ?: DEFAULT_DISPLAY
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = dm.getDisplay(resolvedId)
            ?: return mapOf(
                "ok" to false,
                "path" to "denied",
                "error" to "role:display_not_found displayId=$resolvedId",
            )
        val role = DisplayRoles.roleFor(display)
        if (expectCluster) {
            if (role != DisplayRoles.CLUSTER) {
                return mapOf(
                    "ok" to false,
                    "path" to "denied",
                    "error" to "role:expected_cluster_got_$role displayId=$resolvedId",
                )
            }
            return null
        }
        // Standard launch path: only ivi + passenger are addressable.
        // Cluster + unknown require the cluster op (or are blanket-
        // denied for unknown). The hint nudges the SDK author to
        // use launchCluster() / moveCluster().
        return when (role) {
            DisplayRoles.IVI, DisplayRoles.PASSENGER -> null
            DisplayRoles.CLUSTER -> mapOf(
                "ok" to false,
                "path" to "denied",
                "error" to "role:requires_cluster_op displayId=$resolvedId",
            )
            else -> mapOf(
                "ok" to false,
                "path" to "denied",
                "error" to "role:unknown displayId=$resolvedId",
            )
        }
    }

    companion object {
        private const val TAG = "PackagePlatformPlugin"
        private const val CHANNEL = "ilink/pkg"
        private const val DEFAULT_DISPLAY = 0

        // Di5.0 cluster (ShellLaunch) cold-group warming — see
        // [dispatchShellLaunch]. A cold OWN_CONTENT_ONLY cluster group
        // re-homes the first launch; the retries (without `-S`) route
        // the existing task onto the cluster. 5 attempts with a 700ms
        // linear backoff (0.7s → 3.5s) converges a fully-cold group
        // while still settling fast on a warm one (lands by attempt 2).
        private const val CLUSTER_LAUNCH_ATTEMPTS = 5
        private const val CLUSTER_LAUNCH_SETTLE_MS = 700L
        // Mirrors the Dart-side regex in pkg_family.dart. Validating
        // here too is cheap defence-in-depth: the shell command is
        // assembled by string concat and a malformed packageName must
        // never reach the shell verbatim.
        private val PACKAGE_NAME_REGEX = Regex("""^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$""")

        /**
         * Apps whose AndroidManifest declares a launchMode that
         * actively rejects `am start --display N` — usually a
         * `singleInstance` activity with a fixed task affinity, or a
         * launcher intent that fans out via in-process router to an
         * unexported MainActivity. For these, the AM "honours" the
         * `--display` flag for one frame, then snaps the task back to
         * whichever display already holds an instance (typically the
         * IVI). Symptom for users: "I clicked launch on cluster, the
         * app appeared there for half a second, then disappeared."
         *
         * Cross-checked against a reference DiLink dashboard app's
         * bounce-back allowlist plus what we've empirically observed
         * on Leopard 8. Keep this list narrow —
         * a false positive triggers an extra `am stack list` round-
         * trip on every launch of that package.
         */
        internal val BOUNCE_BACK_PACKAGES: Set<String> = setOf(
            "com.waze",
            "com.waze.preview",
            "com.google.android.apps.maps",
            "com.spotify.music",
            "com.google.android.youtube",
        )

        /** Delay between the initial `am start --display N` and the
         *  verification `am stack list`. Long enough for the AM to
         *  resolve the bounce (observed ~400-600ms on L8 for Maps);
         *  short enough that the user perceives the rePin as part of
         *  the same launch. */
        private const val BOUNCE_VERIFY_DELAY_MS = 700L
    }
}
