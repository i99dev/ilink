package com.i99dev.ilink.display

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Display
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.car.CapabilityRegistry
import com.i99dev.ilink.car.VehicleCapability
import com.i99dev.ilink.car.profiles.CarProfileRegistry
import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.DisplayProfile
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import com.i99dev.ilink.pkg.DishareTransport
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * One-stop platform plugin for the `display` family. Owns:
 *
 *   * MethodChannel `ilink/display` — `list()` snapshot.
 *   * EventChannel `ilink/display/events` — hot-plug pushes.
 *
 * Cardinal rule: this is the ONLY file in the host that imports
 * `android.hardware.display`. The Dart-side `DisplayFamily` calls
 * into this through `DisplayNativeBridge`; tests fake the bridge,
 * never the platform.
 *
 * Wire shape mirrors what mini-apps see (matches the SDK's
 * `DisplaySnapshot` / `DisplayEvent` Zod schemas):
 *
 *     {
 *       id: Int,
 *       name: String,
 *       width: Int,
 *       height: Int,
 *       densityDpi: Int,
 *       isDefault: Bool,
 *       isPresentation: Bool,
 *       isCluster: Bool,    // heuristic: name contains "fission"
 *       role: String,       // ivi | passenger | cluster | unknown
 *                           // — single source of truth for pkg.launch
 *                           // permission gating; see DisplayRoles.kt.
 *       hidden: Bool,       // true for displays the active
 *                           // VehicleProfile says are duplicates /
 *                           // shadows of another (e.g. display 3 on
 *                           // L8 is a mirror of display 5). Picker UX
 *                           // should hide these by default.
 *       overrideLabel: String?,    // friendlier label from the active
 *                                  // profile, e.g. "Driver" for the
 *                                  // cluster display on L8 / L5L.
 *       clusterAvailable: Bool,    // active profile's showCluster flag.
 *                                  // False on L5 / L5U / L7 / HAN L.
 *                                  // Mini-apps read this to pre-empt
 *                                  // showing cluster UI on cars where
 *                                  // the OS doesn't expose it.
 *       cursorDisplayId: Int,      // where pointer should render when
 *                                  // logical surface is this display
 *                                  // (per VehicleProfile remap).
 *       inputSourceDisplayId: Int, // where input from this display is
 *                                  // routed (per VehicleProfile remap).
 *       zoomDisplayId: Int,        // where wm density should land for
 *                                  // zoom requests on this display.
 *     }
 */
class DisplayPlatformPlugin(
    private val applicationContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, "ilink/display").also {
        it.setMethodCallHandler(this)
    }
    private val eventChannel = EventChannel(messenger, "ilink/display/events").also {
        it.setStreamHandler(this)
    }

    private val dm: DisplayManager =
        applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var listener: DisplayManager.DisplayListener? = null

    /** Background dispatcher for the wm-density shell ops. Single-
     *  threaded so consecutive density tweaks serialise — the shell
     *  bridge mustn't juggle concurrent commands. Kept narrow: only
     *  the methods that actually call AdbShellBridge use it. */
    private val adbExecutor = Executors.newSingleThreadExecutor()

    init {
        // D2: when model detection resolves a new trim, re-push a
        // corrected display snapshot to the current subscriber so a
        // mini-app that received the pre-detection Generic one is
        // fixed without waiting for a hot-plug. Cleared in [dispose].
        MiniAppDispatcher.setModelResolvedListener { reEmitSnapshot() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(snapshotList())
            "capabilityBits" -> result.success(capabilityBitsPayload(call))
            "setDensity" -> handleSetDensity(call, result)
            "resetDensity" -> handleResetDensity(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Vehicle capability bitmask for the active variant. Returned as a
     * `{bits: Long, capabilities: [String]}` map so SDK consumers that
     * don't want to round-trip the bit table can read the readable
     * names directly.
     *
     * Optional `fingerprint` arg lets the registry's backend overlay
     * pick a precise (variant, ROM) row when probes have aggregated
     * one — see [CapabilityRegistry.bitsForVariant]. When absent the
     * registry falls back to variant-only or static seed.
     *
     * O(1) — one map lookup + one bit-decode loop bounded by
     * [VehicleCapability.ALL.size].
     */
    private fun capabilityBitsPayload(call: MethodCall): Map<String, Any?> {
        val variantId = MiniAppDispatcher.activeModelIds().firstOrNull()
        val fingerprint = call.argument<String>("fingerprint")
        val bits = CapabilityRegistry.bitsForVariant(variantId, fingerprint)
        return mapOf(
            // Wire as Long so >31 cap entries don't overflow the int
            // shape on the SDK side. Dart picks this up as `int`
            // (Dart ints are arbitrary precision; method-channel
            // marshals Long → int).
            "bits" to bits,
            "capabilities" to VehicleCapability.fromBits(bits),
            "variantId" to variantId,
        )
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // Push initial snapshot so subscribers have a value without
        // racing the first hot-plug. Mirrors the snapshot-plus-stream
        // pattern the family controllers already use on the SDK side.
        events?.success(mapOf("type" to "snapshot", "displays" to snapshotList()))
        attachListener()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        detachListener()
    }

    /**
     * Re-push the current display snapshot to the active subscriber.
     * Fired by [MiniAppDispatcher] when it resolves a new model so a
     * subscriber that got the pre-detection Generic snapshot is
     * corrected without waiting for a hot-plug (D2). Posts to the
     * main thread (`EventSink` is main-thread-only). Null sink (no
     * subscriber yet) is a safe no-op — the eventual [onListen]
     * sends an already-correct snapshot. Same `{type:"snapshot"}`
     * shape [onListen] emits, so the Dart side treats it as an
     * authoritative replace.
     */
    private fun reEmitSnapshot() {
        mainHandler.post {
            sink?.success(mapOf("type" to "snapshot", "displays" to snapshotList()))
        }
    }

    fun dispose() {
        MiniAppDispatcher.setModelResolvedListener(null)
        detachListener()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        adbExecutor.shutdown()
    }

    // ── density ─────────────────────────────────────────────────

    /**
     * `wm density <dpi> -d <displayId>` over loopback ADB. Mini-apps
     * call this to zoom a specific display (typically the cluster)
     * without disturbing the IVI's density. Validates against the
     * active VehicleProfile's `zoomDisplayId` remap so a request on
     * a logical surface lands on the physical surface that actually
     * accepts density overrides on this trim (L8: requesting zoom
     * on display 3 lands on 5).
     *
     * Returns `{ok, displayId, error?}`. `displayId` is the *applied*
     * display id (post-remap) so the caller can reason about where
     * the change actually took effect.
     */
    private fun handleSetDensity(call: MethodCall, result: MethodChannel.Result) {
        val displayId = call.argument<Int>("displayId")
        val dpi = call.argument<Int>("dpi")
        if (displayId == null || dpi == null || dpi <= 0) {
            result.success(
                mapOf("ok" to false, "error" to "displayId + positive dpi required"),
            )
            return
        }
        val applied = activeProfile().zoomDisplayFor(displayId)
        adbExecutor.execute {
            val out = try {
                AdbShellBridge.shell(
                    MiniAppShellCommands.wmDensitySet(applied, dpi),
                    timeoutMs = 4_000L,
                )
            } catch (t: Throwable) {
                "Error: ${t.message ?: t.javaClass.simpleName}"
            }
            val r: Map<String, Any?> = if (out.contains("Error", ignoreCase = true)) {
                mapOf(
                    "ok" to false,
                    "displayId" to applied,
                    "error" to out.trim(),
                )
            } else {
                mapOf(
                    "ok" to true,
                    "displayId" to applied,
                    "error" to null,
                )
            }
            mainHandler.post { result.success(r) }
        }
    }

    /**
     * `wm density reset -d <displayId>` over loopback ADB. Symmetric
     * to [handleSetDensity]; restores stock density on the resolved
     * display. Same remap behaviour.
     */
    private fun handleResetDensity(call: MethodCall, result: MethodChannel.Result) {
        val displayId = call.argument<Int>("displayId")
        if (displayId == null) {
            result.success(mapOf("ok" to false, "error" to "displayId required"))
            return
        }
        val applied = activeProfile().zoomDisplayFor(displayId)
        adbExecutor.execute {
            val out = try {
                AdbShellBridge.shell(
                    MiniAppShellCommands.wmDensityReset(applied),
                    timeoutMs = 4_000L,
                )
            } catch (t: Throwable) {
                "Error: ${t.message ?: t.javaClass.simpleName}"
            }
            val r: Map<String, Any?> = if (out.contains("Error", ignoreCase = true)) {
                mapOf("ok" to false, "displayId" to applied, "error" to out.trim())
            } else {
                mapOf("ok" to true, "displayId" to applied, "error" to null)
            }
            mainHandler.post { result.success(r) }
        }
    }

    // ── internals ────────────────────────────────────────────────

    private fun snapshotList(): List<Map<String, Any?>> {
        // Resolve the active profile once per snapshot — every display
        // in this list shares the same vehicle. Cheap (one map lookup
        // by variantId) but worth caching across the iteration.
        val profile = activeProfile()
        // Profile is authoritative. The `fission_bg_*` virtual display
        // exists on every BYD trim (the OS reuses one Android image
        // across trims) regardless of whether our pixels can actually
        // reach the physical cluster panel. The L5 investigation
        // (.secrets/research/l5/REPORT.md) proved that hardware
        // presence does NOT imply reachability — L5 base has the
        // virtual display but the cluster cell is firmware-locked to
        // BYD-platform-signed callers. We deferred to the table all
        // along; the brief "hardware-truth-wins" experiment was wrong.
        val clusterAvailable = profile.showCluster
        // Full profile (family + passenger) + the IVI's display group: the
        // inputs the centralised [ClusterCastPolicy] needs to derive, per
        // display, the cast-class + safe mechanism. Computed once per
        // snapshot (read-only diagnostics in Phase 1; not yet driving launch).
        val carProfile = CarProfileRegistry.forChain(
            MiniAppDispatcher.activeModelIds(),
        )
        val family = carProfile.dilinkFamily
        val passenger = carProfile.capabilities.passenger
        val iviGroupId = dm.displays
            .firstOrNull { it.displayId == Display.DEFAULT_DISPLAY }
            ?.let { readDisplayGroupId(it) }
        val enumerated = dm.displays.map { d ->
            displayToMap(d, profile, clusterAvailable, family, passenger, iviGroupId)
        }
        // ── Single source of truth for the synthetic FSE surface ──
        // The Di5.0 BYD-container FSE/passenger panel (display 2,
        // `fission_bg_XDJAScreenProjection`) is owner-exclusive to
        // `com.byd.containerservice` and is NOT enumerated by
        // `DisplayManager.getDisplays()` to a non-owner app — yet it
        // IS a real, reachable passenger surface via the DiShare
        // `quickShare` tag `"fse"` (the planner maps displayId 2 →
        // `fse` purely from the profile; `DeviceTagResolver`). It
        // MUST be synthesized HERE — the one `display.list` every
        // consumer reads (slide-panel app picker, mini-app actions
        // sheet, SDK `display.list`, event-channel snapshot) — never
        // in a per-UI provider, or the lists diverge (audit-D1
        // anti-pattern). The whole Di5.0 fork is `capabilities
        // .passenger == DishareQuickShare`; reuse that exact signal
        // so the display list and the launch transport can never
        // disagree. Idempotent: skipped if the OS ever does
        // enumerate display 2.
        val hasFse = enumerated.any { it["id"] == DishareTransport.DISPLAY_ID_FSE }
        // `carProfile` resolved once at the top of this function.
        return if (
            carProfile.capabilities.passenger ==
            PassengerTransport.DishareQuickShare &&
            !hasFse
        ) {
            enumerated + syntheticFseMap(profile, clusterAvailable)
        } else {
            enumerated
        }
    }

    /**
     * Profile-driven synthetic FSE/passenger display, shaped exactly
     * like [displayToMap]'s wire map so every `display.list` consumer
     * treats it identically to a real enumerated display. `id` =
     * [DishareTransport.DISPLAY_ID_FSE] (2) so the launch path
     * resolves it via the same `DeviceTagResolver`/planner route as
     * any real display target; label/remaps come from the active
     * profile so cosmetics stay single-sourced.
     */
    private fun syntheticFseMap(
        profile: DisplayProfile,
        clusterAvailable: Boolean,
    ): Map<String, Any?> {
        val id = DishareTransport.DISPLAY_ID_FSE
        return mapOf(
            "id" to id,
            "name" to "fission_bg_XDJAScreenProjection",
            // The BYD-container fission surfaces are a uniform
            // 1920×720 @ 320 dpi on every Di5.0 car (matches the
            // enumerated `shared_fission_bg_*` 3/4).
            "width" to 1920,
            "height" to 720,
            "densityDpi" to 320,
            "isDefault" to false,
            "isPresentation" to true,
            "isCluster" to false,
            "role" to DisplayRoles.PASSENGER,
            "source" to "PROFILE_SYNTHETIC",
            "confidence" to "HIGH",
            "dimReason" to null,
            "hidden" to false,
            "overrideLabel" to (profile.overrideLabel(id) ?: "FSE Co-pilot"),
            "clusterAvailable" to clusterAvailable,
            "castMode" to "launch",
            // Synthetic FSE is a Di5.0 passenger surface → DiShare.
            "displayGroupId" to null,
            "castClass" to ClusterCastPolicy.wireToken(
                ClusterCastPolicy.ClusterCastClass.NotCluster,
            ),
            "derivedCastMechanism" to ClusterCastPolicy.wireToken(
                ClusterCastPolicy.CastMechanism.Dishare,
            ),
            "cursorDisplayId" to profile.cursorDisplayFor(id),
            "inputSourceDisplayId" to profile.inputDisplayFor(id),
            "zoomDisplayId" to profile.zoomDisplayFor(id),
        )
    }

    private fun activeProfile(): DisplayProfile {
        // The dispatcher's id chain is `[variant, dilinkFamily]`.
        // forChain resolves the finest match, and folds the
        // `dilinkFamily` token onto a known-but-unprofiled nameplate
        // stub so it gets the generation-correct container topology.
        // Returns Generic when the chain is empty / unknown, so we
        // never crash on unrecognised cars.
        return CarProfileRegistry.forChain(MiniAppDispatcher.activeModelIds()).displays
    }

    private fun displayToMap(
        d: Display,
        profile: DisplayProfile,
        clusterAvailable: Boolean,
        family: DilinkFamily,
        passenger: PassengerTransport,
        iviGroupId: Int?,
    ): Map<String, Any?> {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        d.getRealMetrics(metrics)
        val name = d.name ?: ""
        val displayId = d.displayId
        val cls = DisplayClassifier.classifyDisplay(d, profile)
        // Read-only cast-policy fields (Phase 1) — the dynamic, DiLink-keyed
        // cast-class + safe mechanism the policy WOULD pick. Surfaced for
        // on-car verification against today's static `castMode`; not yet
        // driving the launch path.
        val groupId = readDisplayGroupId(d)
        val castClass = ClusterCastPolicy.classifyCastClass(
            role = cls.role,
            family = family,
            displayGroupId = groupId,
            iviGroupId = iviGroupId,
            name = name,
            profileSaysProject = profile.castsViaProjection(displayId),
        )
        val derivedMech = ClusterCastPolicy.mechanismFor(cls.role, family, passenger, castClass)
        return mapOf(
            "id" to displayId,
            "name" to name,
            "width" to metrics.widthPixels,
            "height" to metrics.heightPixels,
            "densityDpi" to metrics.densityDpi,
            "isDefault" to (displayId == Display.DEFAULT_DISPLAY),
            "isPresentation" to ((d.flags and Display.FLAG_PRESENTATION) != 0),
            // Derived from `role` so the two flags can never disagree.
            // Kept for SDK consumers that already filter on isCluster
            // (see ilink-sdk/src/runtime/display.ts); migrate to
            // `role` and we can drop it.
            "isCluster" to (cls.role == DisplayRoles.CLUSTER),
            "role" to cls.role,
            // New in 1.5.3 — Phase 2 consolidation:
            "source" to cls.source.name,         // MARKER|NAME_KW|CACHE_HIT|DEFAULT
            "confidence" to cls.confidence.name, // HIGH|MEDIUM
            "dimReason" to cls.dimReason,        // 'shadow' | 'cluster-vendor-locked' | null
            // Legacy `hidden` boolean — derived from dimReason for
            // existing SDK consumers that filter on it. New consumers
            // should read `dimReason` and dim (not hide). Removed in
            // a later release once every consumer migrates.
            "hidden" to (cls.dimReason != null),
            "overrideLabel" to profile.overrideLabel(displayId),
            "clusterAvailable" to clusterAvailable,
            // 'project' → cast via our own VirtualDisplay (L7 XDJA cluster);
            // 'launch' → the existing launchCluster / displayId launch path.
            "castMode" to if (profile.castsViaProjection(displayId)) "project" else "launch",
            // Phase-1 read-only cast-policy diagnostics (see ClusterCastPolicy).
            "displayGroupId" to groupId,
            "castClass" to ClusterCastPolicy.wireToken(castClass),
            "derivedCastMechanism" to ClusterCastPolicy.wireToken(derivedMech),
            "cursorDisplayId" to profile.cursorDisplayFor(displayId),
            "inputSourceDisplayId" to profile.inputDisplayFor(displayId),
            "zoomDisplayId" to profile.zoomDisplayFor(displayId),
        )
    }

    /** Cached reflection handle for `Display.getDisplayGroupId()` (@hide,
     *  API 33+). Null on ROMs lacking it → the policy treats a Di5.1 cluster
     *  with no group signal as a hazard (projected), the safe direction. */
    @Volatile private var groupIdMethodResolved = false
    @Volatile private var groupIdMethod: java.lang.reflect.Method? = null

    private fun readDisplayGroupId(d: Display): Int? {
        if (!groupIdMethodResolved) {
            synchronized(this) {
                if (!groupIdMethodResolved) {
                    groupIdMethod = runCatching {
                        Display::class.java.getMethod("getDisplayGroupId")
                    }.getOrNull()
                    groupIdMethodResolved = true
                }
            }
        }
        val m = groupIdMethod ?: return null
        return runCatching { m.invoke(d) as? Int }.getOrNull()
    }

    private fun attachListener() {
        if (listener != null) return
        val l = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {
                pushEvent("added", displayId)
            }
            override fun onDisplayRemoved(displayId: Int) {
                pushEvent("removed", displayId)
            }
            override fun onDisplayChanged(displayId: Int) {
                pushEvent("changed", displayId)
            }
        }
        dm.registerDisplayListener(l, mainHandler)
        listener = l
    }

    private fun detachListener() {
        listener?.let { dm.unregisterDisplayListener(it) }
        listener = null
    }

    private fun pushEvent(kind: String, displayId: Int) {
        // Re-snapshot the affected display when present (events fire
        // even when the display is gone, in which case we just send
        // the id with no metrics). Cheap; one map lookup.
        val display = dm.getDisplay(displayId)
        val profile = activeProfile()
        // Mirror snapshotList()'s derivation so the wire shape stays
        // consistent across `list` and `events`. Profile flag is
        // authoritative — see snapshotList() comment for rationale.
        val clusterAvailable = profile.showCluster
        val carProfile = CarProfileRegistry.forChain(
            MiniAppDispatcher.activeModelIds(),
        )
        val family = carProfile.dilinkFamily
        val passenger = carProfile.capabilities.passenger
        val iviGroupId = dm.displays
            .firstOrNull { it.displayId == Display.DEFAULT_DISPLAY }
            ?.let { readDisplayGroupId(it) }
        val payload = mapOf<String, Any?>(
            "type" to kind,
            "displayId" to displayId,
            "display" to (
                display?.let {
                    displayToMap(it, profile, clusterAvailable, family, passenger, iviGroupId)
                }
            ),
        )
        mainHandler.post { sink?.success(payload) }
    }
}
