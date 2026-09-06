package com.i99dev.ilink.nav

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.i99dev.ilink.nav.controller.HudController
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.ingest.A11yNavSource
import com.i99dev.ilink.nav.ingest.NavAppA11y
import com.i99dev.ilink.nav.ingest.NavLocationCache
import com.i99dev.ilink.nav.ingest.NotifNavSource
import com.i99dev.ilink.nav.ingest.NavSource
import com.i99dev.ilink.nav.ingest.NavSourceRegistry
import com.i99dev.ilink.nav.ingest.NavManeuverBus
import com.i99dev.ilink.nav.ingest.WazeArrowBounds
import com.i99dev.ilink.nav.ingest.WazeArrowBus
import com.i99dev.ilink.nav.ingest.WazeArrowCaptureService
import com.i99dev.ilink.nav.ingest.WazeCaptureConsentActivity
import com.i99dev.ilink.nav.ingest.WazeCaptureGate
import com.i99dev.ilink.nav.ingest.WazeLaneBounds
import com.i99dev.ilink.nav.ingest.WazeLaneBus
import com.i99dev.ilink.nav.ingest.WazeProjectionHolder
import com.i99dev.ilink.nav.transport.AmapBroadcastTransport
import com.i99dev.ilink.nav.transport.HalCanFidTransport
import com.i99dev.ilink.nav.transport.DefaultHudRenderer
import com.i99dev.ilink.nav.transport.HudTransport
import com.i99dev.ilink.nav.transport.SomeIpHudTransport
import com.i99dev.ilink.nav.transport.canfid.DaemonFidWriter
import com.i99dev.ilink.nav.transport.someip.SelectedSomeIpVariant
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `ilink/nav_hud` — the Flutter bridge for the factory-cluster Nav-HUD.
 *
 * Pushes turn-by-turn / lane guidance (sourced from Google Maps / Waze /
 * Yandex) onto the BYD instrument cluster via the preferred [HudTransport]
 * (SOME/IP in-process, ADB-free → CAN-FID HAL fallback). The Dart side arms
 * this on the voice "navigate" hand-off and disarms when nav ends.
 *
 * Methods:
 *   * `probe`   → {someip:Bool, canfid:Bool} — which transports this car offers (M0).
 *   * `arm`     → {ok} — start ingestion + drive the cluster.
 *   * `disarm`  → {ok} — stop + clear the cluster.
 *   * `pin`     {source?} → {ok} — force a nav app (null = auto-arbitrate).
 *
 * `probe`/`arm`/`disarm` touch PackageManager / bindService, so they run on a
 * worker and post the [MethodChannel.Result] back on the main looper.
 */
class NavHudPlatformPlugin(
    private val appContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "nav-hud-plugin") }
    private val main = Handler(Looper.getMainLooper())

    // Preference order: ADB-free SOME/IP first, privileged HAL fallback second.
    // DefaultHudRenderer = the extracted icon cache + guideLine + ETA formatter.
    // CAN-FID's privileged sink is null until the daemon guidance verb lands;
    // it reports unavailable until then, so SOME/IP is the active path.
    // The daemon FID writer is INERT until M0 calibration (ready() == false),
    // so CAN-FID is not selected and nothing fires — safe by default.
    private val fidWriter = DaemonFidWriter()
    // SOME/IP (5.0UI RoadInfo) and CAN-FID (7.0UI instrument-HAL) are mutually
    // exclusive by DiLink generation (each gates on ClusterProtocol), so the
    // controller's "first available" selection picks the right one per car.
    private val transports: List<HudTransport> = listOf(
        // The variant is resolved LIVE, per access, from NavHudOptions (TASK-003)
        // rather than captured here: this list is built at plugin construction,
        // before options are even loaded and long before the user can open the
        // settings panel, so a captured variant could never be reverted without a
        // rebuild. `SelectedSomeIpVariant` keeps the transport itself untouched.
        SomeIpHudTransport(
            appContext,
            DefaultHudRenderer,
            SelectedSomeIpVariant(
                DefaultHudRenderer,
                // Only consulted when a variant that has per-model tables is
                // selected (today: launcher_map_cn's map-camera pose).
                { NavHudOptions.detectedModelName },
            ) { NavHudOptions.resolvedSomeIpVariant },
        ),
        HalCanFidTransport(appContext),
    )
    // Additive output: BYD's native Amap cluster widget, driven ALONGSIDE the
    // selected primary (clean ASCII units + IS_BYD_MAP so the cluster doesn't
    // render its own Chinese-locale formatting). Self-gates on
    // NavHudOptions.amapWidget — no-op when the user turns it off.
    private val auxTransports: List<HudTransport> = listOf(
        AmapBroadcastTransport(appContext),
    )
    private val controller = HudController(transports, auxTransports)

    // Accessibility nav sources — config-driven view-id scrapers (Maps/Yandex
    // get the maneuver from cue/balloon text; Waze a11y gives dist/road/ETA, its
    // arrow-maneuver lands with the capture source). View-ids are the reference ground
    // truth, re-verified on the BYD ROM at M2. Notification + MediaProjection
    // sources extend this list as they land.
    private val sources: List<NavSource> = listOf(
        // Rich a11y for the big three: a11y supplies distance/road/ETA; the
        // MANEUVER (turn direction) comes from the notification via NavManeuverBus
        // — on these apps the a11y maneuver node is a street / a non-phrase / a
        // bitmap, so classifying it defaults ("always default arrow"). The bus is
        // read per package via the existing maneuverProvider seam, with a window
        // == this source's TTL so the arrow is as fresh as the frame it decorates.
        // (Notif + a11y share one NavSourceId arbiter slot; both carry the same bus
        // maneuver so the arrow is correct whichever wins, and a11y normally wins
        // via its 200 ms cadence so distance/road stay precise.)
        A11yNavSource(
            NavSourceId.GOOGLE_MAPS, 5_000L,
            setOf(
                "com.google.android.apps.maps",
                "app.revanced.android.apps.maps",
                // GBox-sandboxed Google Maps: the system sees this wrapper package as
                // the foreground window, but it runs the real Maps APK so the
                // com.google.android.apps.maps:id/* view-ids (NavAppA11y.GOOGLE_MAPS)
                // still resolve. (On-car verify the view-id namespace isn't rewritten.)
                "com.gbox.com.google.android.apps.maps",
            ),
            NavAppA11y.GOOGLE_MAPS,
            // Maps reports under any of its packages; try each (one is fresh).
            maneuverProvider = {
                NavManeuverBus.latest("com.google.android.apps.maps", 5_000L)
                    ?: NavManeuverBus.latest("app.revanced.android.apps.maps", 5_000L)
                    ?: NavManeuverBus.latest("com.gbox.com.google.android.apps.maps", 5_000L)
            },
        ),
        // Waze arrow is a bitmap (capture pipeline) — prefer the captured arrow,
        // then fall back to the notification-derived maneuver. One ladder.
        A11yNavSource(
            NavSourceId.WAZE, 40_000L, setOf("com.waze"), NavAppA11y.WAZE,
            maneuverProvider = { WazeArrowBus.latest() ?: NavManeuverBus.latest("com.waze", 40_000L) },
            // Lane glyphs are bitmaps too → captured + classified, delivered via the bus.
            laneProvider = { WazeLaneBus.latest() },
        ),
        A11yNavSource(
            NavSourceId.YANDEX, 10_000L,
            setOf("ru.yandex.yandexmaps"), // yandexnavi is canvas-only → unsupported
            NavAppA11y.YANDEX,
            maneuverProvider = { NavManeuverBus.latest("ru.yandex.yandexmaps", 10_000L) },
        ),
        // Universal notification source — every other app in NavAppRegistry.
        NotifNavSource(),
    )
    private val registry =
        NavSourceRegistry(sources, controller, NavLocationCache.forContext(appContext))

    init {
        // Load persisted user options (transliterate / amapWidget / …) once so a
        // choice survives car restart before the first frame is pushed.
        NavHudOptions.init(appContext)
        // Persistent enable: if the user left the HUD ON, re-arm automatically on
        // app start so they never have to re-activate it each launch (it stays on
        // until they switch it off). Off-main — a11y enable + service bind do I/O.
        if (NavHudOptions.hudEnabled) {
            Thread({ runCatching { armHud() } }, "navhud-autoarm").apply { isDaemon = true }.start()
        }
    }

    /** Arm the HUD pipeline: ensure a11y is enabled+bound, start the nav sources,
     *  open the Waze capture gate. Shared by the `arm` channel call and the
     *  auto-arm-on-init path. */
    private fun armHud() {
        com.i99dev.ilink.input.A11yHealer.ensureEnabled(appContext)
        registry.start()
        WazeCaptureGate.armed = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> onWorker(result) {
                mapOf("someip" to available("SOME_IP"), "canfid" to available("CAN_FID"))
            }
            "arm" -> onWorker(result) {
                // The nav sources read foreground windows through our a11y
                // service. armHud() ensures it's ENABLED + bound so arming never
                // requires a manual Settings/diagnostics enable (we hold
                // WRITE_SECURE_SETTINGS). Persist ON so it auto-arms next launch.
                armHud()
                NavHudOptions.setHudEnabled(true)
                mapOf("ok" to true)
            }
            "disarm" -> onWorker(result) {
                registry.stop()
                WazeCaptureGate.armed = false
                WazeArrowCaptureService.stop(appContext)
                WazeArrowBounds.clear()
                WazeLaneBounds.clear()
                WazeLaneBus.clear()
                NavHudOptions.setHudEnabled(false) // persist OFF (stays off until re-enabled)
                mapOf("ok" to true)
            }
            // One-time MediaProjection consent for the Waze arrow capture (the arrow is
            // a graphic, only readable as pixels). No dialog if already granted this
            // process. Decline degrades gracefully (arrow falls back to straight).
            "requestArrowCapture" -> onWorker(result) {
                WazeCaptureConsentActivity.request(appContext)
                mapOf("ok" to true, "consent" to WazeProjectionHolder.hasConsent)
            }
            "pin" -> onWorker(result) {
                registry.pinned = parseSource(call.argument<String?>("source"))
                mapOf("ok" to true)
            }
            "setOption" -> onWorker(result) {
                val key = call.argument<String>("key")
                val value = call.argument<Boolean>("value")
                if (key != null && value != null) NavHudOptions.set(key, value)
                optionsMap()
            }
            "options" -> onWorker(result) { optionsMap() }
            // Cluster-protocol override: "auto" (drive all available) / "someip" /
            // "canfid". Lets the user force a channel on a trim where auto-drive-all
            // isn't right. Takes effect on the next arm.
            "setClusterProtocol" -> onWorker(result) {
                call.argument<String>("value")?.let { NavHudOptions.setClusterProtocol(it) }
                optionsMap()
            }
            // The revert switch (TASK-003): flip to `ui7` on a car to pin the wire
            // back to today's proven bytes — no rebuild, no reinstall.
            "setSomeIpVariant" -> onWorker(result) {
                call.argument<String>("value")?.let { NavHudOptions.setSomeIpVariant(it) }
                optionsMap()
            }
            // Live status — what the HUD is actually doing right now (so the
            // on-car test shows the SOME/IP bind result + data flowing).
            "status" -> onWorker(result) {
                // Self-heal while armed: if the a11y binding our nav sources read
                // through has crashed (process death without a ROM rebind), the
                // panel sits on "Waiting for a navigation app…" with no data. The
                // 1 s status poll is the fastest path to notice + recover it with
                // no user action. No-op when healthy; rate-limited internally.
                if (controller.isArmed) {
                    com.i99dev.ilink.input.A11yHealer.healIfCrashed(appContext)
                }
                val winner = registry.lastWinner
                mapOf(
                    "armed" to controller.isArmed,
                    "transport" to controller.activeTransportName,
                    "connected" to controller.activeConnected,
                    "pushed" to controller.pushedFrames,
                    "drivingApp" to winner?.source?.name,
                    "maneuver" to winner?.maneuverIcon,
                    "distanceMeters" to winner?.distanceMeters,
                    "road" to winner?.roadName,
                    "rawManeuver" to winner?.rawManeuver,
                )
            }
            // Push a synthetic maneuver through the live pipeline — confirms the
            // cluster RENDERS via the selected transport, without a nav app
            // navigating. The single best on-car transport smoke test.
            "emitTest" -> onWorker(result) {
                // Fail loud when not armed — otherwise the smoke test reports
                // success while pushing nothing.
                if (!controller.isArmed) {
                    mapOf("ok" to false, "reason" to "not_armed")
                } else {
                    val code = call.argument<Int>("maneuver") ?: 1
                    val dist = call.argument<Int>("distance") ?: 200
                    controller.submit(
                        NavGuidance(
                            maneuverIcon = code,
                            distanceMeters = dist,
                            roadName = "Test Rd",
                            remainingDistanceMeters = 5_000,
                            remainingTimeSeconds = 600,
                            source = NavSourceId.UNKNOWN,
                        ),
                        10_000L,
                    )
                    mapOf("ok" to true)
                }
            }
            // M0 read-only diagnostics — run on the car to decide the transport.
            "diagnose" -> onWorker(result) {
                mapOf(
                    "someip" to available("SOME_IP"),
                    "canfid" to available("CAN_FID"),
                    // is the BYD instrument HAL class on the (app) classpath?
                    // (the package name lives only in BydAutoFeatureIdsCatalog).
                    "instrumentHalClass" to com.i99dev.ilink.car.BydAutoFeatureIdsCatalog
                        .isInstrumentDevicePresent(),
                    // is the daemon reachable (CAN-FID path)?
                    "daemon" to runCatching {
                        com.i99dev.ilink.adb.AdbShellBridge.daemonClient().ping()
                    }.getOrDefault(false),
                    "fidVerified" to fidWriter.verified,
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Boolean option snapshot + the string cluster-protocol override, in one map
     *  for the Dart settings surface. */
    private fun optionsMap(): Map<String, Any> =
        NavHudOptions.snapshot() + mapOf(
            "clusterProtocol" to NavHudOptions.clusterProtocol,
            // Both the raw preference AND what it resolves to: on `auto` the UI
            // must be able to show WHICH variant the model actually selected,
            // otherwise a tester can't tell an override from a default.
            "someIpVariant" to NavHudOptions.someIpVariant,
            "someIpVariantResolved" to NavHudOptions.resolvedSomeIpVariant,
        )

    private fun parseSource(s: String?): NavSourceId? = when (s?.lowercase()) {
        "google_maps", "gmaps", "maps" -> NavSourceId.GOOGLE_MAPS
        "waze" -> NavSourceId.WAZE
        "yandex" -> NavSourceId.YANDEX
        "amap", "gaode" -> NavSourceId.AMAP
        else -> null
    }

    private fun available(name: String): Boolean =
        transports.firstOrNull { it.name == name }
            ?.let { runCatching { it.isAvailable() }.getOrDefault(false) } ?: false

    private fun onWorker(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            val r = runCatching { block() }
            main.post {
                r.onSuccess { result.success(it) }
                    .onFailure {
                        Log.w(TAG, "nav_hud call failed", it)
                        result.error("nav_hud_error", it.message, null)
                    }
            }
        }
    }

    fun dispose() {
        runCatching { registry.stop() }
        runCatching { controller.dispose() }
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    companion object {
        private const val TAG = "NavHudPlugin"
        private const val CHANNEL = "ilink/nav_hud"
    }
}
