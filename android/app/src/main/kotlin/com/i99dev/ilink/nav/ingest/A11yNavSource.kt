package com.i99dev.ilink.nav.ingest

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavLane
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.ManeuverCatalog
import com.i99dev.ilink.nav.logic.ManeuverTextMap
import com.i99dev.ilink.nav.logic.NavTextParse

/** Per-app accessibility view-ids (suffixes appended to the live package name).
 *  Adding an app = one [NavViewIds] — no engine edits. View-ids verified from
 *  the reference on its ROM; **flag for BYD-cluster re-verify** (M2 on-car). */
data class NavViewIds(
    val distance: String,
    /** Optional unit/metrics node, read separately and appended to [distance].
     *  Yandex Maps splits the maneuver distance into "1.5" + " km" across two
     *  views, so the number alone ("1.5") is unparseable without it. */
    val distanceUnit: String? = null,
    val road: String,
    /** Maneuver source — a node whose text/contentDescription classifies via
     *  [ManeuverTextMap]. null = no text maneuver (e.g. Waze arrow → needs capture). */
    val maneuver: String? = null,
    val maneuverIsContentDesc: Boolean = false,
    val timeToDest: String? = null,
    val distToDest: String? = null,
    /** Optional next-step node ("then turn… onto X"), read as contentDescription and
     *  cleaned to the secondary road. Google Maps `:id/next_step_instruction_container`. */
    val nextStep: String? = null,
)

/**
 * A config-driven accessibility nav source: reads [ids] off the foreground
 * window, parses with [NavTextParse] + [ManeuverTextMap], and emits canonical
 * [NavGuidance]. Self-throttles to 200 ms/app (ground truth). Reusable across
 * every app that exposes text/contentDescription — no per-app code.
 */
class A11yNavSource(
    override val id: NavSourceId,
    override val ttlMs: Long,
    override val packages: Set<String>,
    private val ids: NavViewIds,
    private val throttleMs: Long = 200L,
    /** Maneuver when there's no classifiable text node: the notification-derived
     *  code from NavManeuverBus (Maps/Yandex), or the captured arrow (Waze). */
    private val maneuverProvider: (() -> Int?)? = null,
    /** Lane guidance for apps whose lanes come from capture (Waze) — the latest
     *  classified [NavLane], attached to the emitted frame. null = no lane source. */
    private val laneProvider: (() -> NavLane?)? = null,
) : NavSource, NavA11yHandler {

    private var emit: ((NavGuidance) -> Unit)? = null
    @Volatile private var lastReadMs = 0L

    override fun start(onFrame: (NavGuidance) -> Unit, onGone: (NavSourceId) -> Unit) {
        // a11y has no "navigation ended" signal — onGone is unused here; the
        // controller's staleness backstop covers an a11y window that disappears.
        emit = onFrame
        NavA11yDispatcher.register(this)
    }

    override fun stop() {
        NavA11yDispatcher.unregister(this)
        emit = null
    }

    override fun onWindow(root: AccessibilityNodeInfo, pkg: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastReadMs < throttleMs) return
        lastReadMs = now


        // Some apps (Yandex Maps) split the maneuver distance into a number node
        // + a separate unit node ("1.5" + " km"); rejoin before parsing.
        val distNum = text(root, pkg + ids.distance)
        val distUnit = ids.distanceUnit?.let { text(root, pkg + it) }
        val distStr = if (distNum != null && distUnit != null) "$distNum $distUnit" else distNum
        val dist = NavTextParse.distanceMeters(distStr) ?: return
        // Road is emitted RAW; transliteration is centralized at the controller
        // choke point (one place, applied to every source + transport).
        val rawRoad = text(root, pkg + ids.road)
        val road = rawRoad ?: ""
        val rawManeuver = ids.maneuver?.let { suffix ->
            if (ids.maneuverIsContentDesc) desc(root, pkg + suffix) else text(root, pkg + suffix)
        }
        val maneuver = rawManeuver?.let { ManeuverTextMap.classify(it) }
            ?: maneuverProvider?.invoke() ?: ManeuverCatalog.STRAIGHT
        val remTime = ids.timeToDest?.let { NavTextParse.timeSeconds(text(root, pkg + it)) }
        val remDist = ids.distToDest?.let { NavTextParse.distanceMeters(text(root, pkg + it)) }
        // Secondary "then… onto X" road (Google Maps) — raw text/desc, cleaned of its
        // leading maneuver verb; transliteration happens later at the controller choke.
        val secondary = ids.nextStep?.let {
            NavTextParse.cleanNextStep(desc(root, pkg + it) ?: text(root, pkg + it))
        } ?: ""

        emit?.invoke(
            NavGuidance(
                maneuverIcon = maneuver,
                distanceMeters = dist,
                roadName = road,
                remainingDistanceMeters = remDist,
                remainingTimeSeconds = remTime,
                secondaryRoadName = secondary,
                lane = laneProvider?.invoke(),
                source = id,
                // Diagnostics: show both the maneuver node + road node text so the
                // "always left" arrow can be traced to the exact source string.
                rawManeuver = "m='${rawManeuver ?: ""}' r='${rawRoad ?: ""}'",
            ),
        )
    }

    private fun node(root: AccessibilityNodeInfo, viewId: String): AccessibilityNodeInfo? =
        runCatching {
            root.findAccessibilityNodeInfosByViewId(viewId)?.firstOrNull()?.also {
                // Bypass the accessibility node CACHE: between a nav app's a11y events
                // getRootInActiveWindow() serves a cached tree, so a polled re-read
                // returns the STALE text (e.g. distance frozen at its last event value
                // while the car keeps moving). refresh() forces the framework to
                // re-fetch this node's live state, so the poll reads the real value.
                runCatching { it.refresh() }
            }
        }.getOrNull()

    private fun text(root: AccessibilityNodeInfo, viewId: String): String? =
        node(root, viewId)?.text?.toString()?.trim()?.ifEmpty { null }

    private fun desc(root: AccessibilityNodeInfo, viewId: String): String? =
        node(root, viewId)?.contentDescription?.toString()?.trim()?.ifEmpty { null }
}

/** Verified view-id configs (the reference ground truth). Re-verify on the BYD ROM (M2). */
object NavAppA11y {
    // Maneuver is intentionally null: the cue node ":id/top_cue_text" holds the
    // STREET, not the direction, so classifying it defaults (the "always default
    // arrow" bug). The direction comes from the notification via NavManeuverBus
    // (wired as this source's maneuverProvider). a11y here owns distance/road/ETA.
    val GOOGLE_MAPS = NavViewIds(
        distance = ":id/distance_text",
        road = ":id/top_cue_text",
        maneuver = null, // was ":id/top_cue_text" (street, not direction) → bus
        timeToDest = ":id/navigation_time_remaining_label",
        // "then turn… onto X" → secondary road (feeds Amap NEXT_NEXT_ROAD_NAME).
        nextStep = ":id/next_step_instruction_container",
    )
    // Yandex MAPS (ru.yandex.yandexmaps) — verified on-car 2026-06-22. The
    // maneuver balloon splits distance into number + unit; maneuver is the
    // arrow's contentDescription ("Turn left"). Yandex NAVI (yandexnavi) draws
    // its maneuver on the map canvas (no a11y nodes) + posts no notification, so
    // it can't drive turn-by-turn — it falls through here (no balloon → no frame).
    // Yandex posts NO maneuver in its notification (verified on-car: title is just
    // "Navigator is running", no RemoteViews, no large-icon), so the direction MUST
    // come from the a11y maneuver-balloon arrow's contentDescription. The bus stays
    // wired as a fallback (harmless — it's empty for Yandex). a11y also supplies the
    // split distance (number+unit) + road + ETA.
    val YANDEX = NavViewIds(
        distance = ":id/text_maneuverballoon_distance",
        distanceUnit = ":id/text_maneuverballoon_metrics",
        road = ":id/text_nextstreet",
        maneuver = ":id/image_maneuverballoon_maneuver",
        maneuverIsContentDesc = true,
        timeToDest = ":id/textview_eta_time",
        distToDest = ":id/textview_eta_distance",
    )

    // Waze maneuver is an arrow BITMAP (perceptual hash) — a11y gives dist/road/
    // ETA only; the maneuver comes from the arrow-capture source (deferred).
    val WAZE = NavViewIds(
        distance = ":id/navBarDistance",
        road = ":id/navBarStreetLine",
        maneuver = null,
        timeToDest = ":id/lblTimeToDestination",
        distToDest = ":id/lblDistanceToDestination",
    )
}
