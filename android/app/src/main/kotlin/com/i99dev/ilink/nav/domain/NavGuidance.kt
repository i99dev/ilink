package com.i99dev.ilink.nav.domain

/**
 * The ONE canonical, immutable nav-guidance frame. Every [com.i99dev.ilink]
 * NavSource (Google Maps / Waze / Yandex) converges here; every HudTransport
 * consumes here. Field set mirrors the reference's `i60` HudNavigationData
 * plus the `g60` lane sub-struct.
 *
 * Nullable Int fields are "not present" (not 0) and are GATED at the transport:
 * a frame is only worth pushing if [distanceMeters] != null && >= 0. Pure data,
 * host-JVM testable, no Android imports.
 */
data class NavGuidance(
    /** Maneuver icon id — HAL TURN_ICON_* (1..49). 0 = none; >49 → unknown →
     *  SUPPRESS the icon, never default to a real arrow (safety). */
    val maneuverIcon: Int,
    /** Distance to the maneuver, metres. Push-gate: only push when >= 0. */
    val distanceMeters: Int?,
    /** Road/street name for the maneuver. Never null ("" allowed). */
    val roadName: String,
    val remainingDistanceMeters: Int?,
    val remainingTimeSeconds: Int?,
    val secondaryRoadName: String = "",
    val cameraType: Int? = null,
    val cameraDistance: Int? = null,
    val cameraState: Int? = null,
    val safetyType: Int? = null,
    val safetyDistance: Int? = null,
    val safetyState: Int? = null,
    val trafficLightColor: String? = null,
    val trafficLightSeconds: String? = null,
    val lane: NavLane? = null,
    /** Which app produced this frame. METADATA — excluded from delta/coalesce. */
    val source: NavSourceId = NavSourceId.UNKNOWN,
    /** Diagnostics: the raw maneuver text the source read before classification
     *  (so the arrow can be debugged on-car). METADATA — not coalesced. */
    val rawManeuver: String? = null,
    /** Vehicle position at the time this frame was ingested, WGS-84 degrees.
     *  null = no fix / no location permission (the transports must then fall back
     *  to exactly their previous behaviour). METADATA — deliberately EXCLUDED from
     *  delta/coalesce: a drifting GPS coordinate must never, on its own, push a
     *  frame to the cluster. See [com.i99dev.ilink.nav.logic.NavGuidanceCoalescer]. */
    val lat: Double? = null,
    /** See [lat]. METADATA — not coalesced. */
    val lon: Double? = null,
    /** Course over ground in degrees clockwise from true north (0..360), or null
     *  when unknown. METADATA — not coalesced. */
    val heading: Double? = null,
) {
    /** True when this frame carries a usable position (both coordinates present). */
    val hasPosition: Boolean get() = lat != null && lon != null

    /** Copy of this frame decorated with [fix]. A null [fix] leaves the frame
     *  untouched, so "no fix / no permission" is a strict no-op. */
    fun withPosition(fix: NavFix?): NavGuidance =
        if (fix == null) this else copy(lat = fix.lat, lon = fix.lon, heading = fix.heading)

    /** A frame is "drawable" only if it has a non-negative distance. Mirrors
     *  the reference's `distance >= 0` push gate. */
    val isDrawable: Boolean get() = distanceMeters != null && distanceMeters >= 0

    /** Icon is a real, drawable maneuver (1..49). 0/None and >49/unknown are NOT
     *  drawable — the transport must suppress the icon (write 0), never show a
     *  wrong arrow. Safety: a parser glitch must not paint a confident turn. */
    val hasDrawableIcon: Boolean get() = maneuverIcon in 1..49
}

/** Lane guidance (`g60`). [laneCodes] = per-lane arrow codes; [activeIndices] =
 *  which lanes are the recommended ones (parallel to [laneCodes]). */
data class NavLane(
    val laneCodes: List<Int>,
    val activeIndices: List<Boolean>,
    val distanceToSplitMeters: Int = -1,
)

/** Known nav apps (for arbitration + provenance). The universal notification
 *  source recognises all of these; the rich a11y sources cover the first few. */
enum class NavSourceId {
    GOOGLE_MAPS, WAZE, YANDEX, AMAP, BAIDU, HERE, SYGIC, TOMTOM, TOMTOM_AMIGO,
    PETAL, OSMAND, ORGANIC_MAPS, TWOGIS, KAKAO, NAVER, MAPY, MAGIC_EARTH,
    MAPS_ME, FLITSMEISTER, UNKNOWN
}
