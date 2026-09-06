package com.i99dev.ilink.nav.ingest

import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * The single source of truth mapping nav-app packages → [NavSourceId], plus each
 * app's display name + freshness TTL. Adding a nav app = ONE row here — the
 * universal notification source then recognises it with zero other changes.
 *
 * Package ids verified against Play/APKMirror/F-Droid (2026-06). Ones flagged
 * below are re-confirmed on-device. The notification channel works for every app
 * that posts an ongoing turn-by-turn notification; a11y/perceptual sources cover
 * the richer subset (Maps/Waze/Yandex).
 */
object NavAppRegistry {

    data class NavApp(
        val id: NavSourceId,
        val displayName: String,
        val packages: Set<String>,
        val ttlMs: Long = 10_000L,
    )

    val APPS: List<NavApp> = listOf(
        // verified-rich (a11y/ground-truth)
        NavApp(NavSourceId.GOOGLE_MAPS, "Google Maps", setOf("com.google.android.apps.maps", "app.revanced.android.apps.maps", "com.gbox.com.google.android.apps.maps"), 5_000L),
        NavApp(NavSourceId.WAZE, "Waze", setOf("com.waze"), 40_000L),
        // Yandex NAVI (ru.yandex.yandexnavi) draws its maneuver on the map canvas
        // (no a11y nodes) and posts no usable turn-by-turn notification, so it can't
        // drive the HUD — intentionally NOT listed (don't advertise unsupported TBT).
        NavApp(NavSourceId.YANDEX, "Yandex Maps", setOf("ru.yandex.yandexmaps"), 10_000L),
        // notification-channel apps ("support most maps")
        NavApp(NavSourceId.AMAP, "Amap (AutoNavi)", setOf("com.autonavi.minimap")),
        NavApp(NavSourceId.BAIDU, "Baidu Maps", setOf("com.baidu.BaiduMap")), // ⚠ confirm casing on-device
        NavApp(NavSourceId.HERE, "HERE WeGo", setOf("com.here.app.maps")),
        NavApp(NavSourceId.SYGIC, "Sygic", setOf("com.sygic.aura")),
        NavApp(NavSourceId.TOMTOM, "TomTom GO", setOf("com.tomtom.gplay.navapp")),
        NavApp(NavSourceId.TOMTOM_AMIGO, "TomTom AmiGO", setOf("com.tomtom.speedcams.android.map")),
        NavApp(NavSourceId.PETAL, "Petal Maps", setOf("com.huawei.maps.app")),
        NavApp(NavSourceId.OSMAND, "OsmAnd", setOf("net.osmand", "net.osmand.plus", "net.osmand.dev")),
        NavApp(NavSourceId.ORGANIC_MAPS, "Organic Maps", setOf("app.organicmaps")),
        NavApp(NavSourceId.TWOGIS, "2GIS", setOf("ru.dublgis.dgismobile")),
        NavApp(NavSourceId.KAKAO, "Kakao Map", setOf("net.daum.android.map")),
        NavApp(NavSourceId.NAVER, "Naver Map", setOf("com.nhn.android.nmap")),
        NavApp(NavSourceId.MAPY, "Mapy.com", setOf("cz.seznam.mapy")),
        NavApp(NavSourceId.MAGIC_EARTH, "Magic Earth", setOf("com.generalmagic.magicearth")),
        NavApp(NavSourceId.MAPS_ME, "Maps.me", setOf("com.mapswithme.maps.pro")),
        NavApp(NavSourceId.FLITSMEISTER, "Flitsmeister", setOf("nl.flitsmeister")),
    )

    private val BY_PACKAGE: Map<String, NavApp> = buildMap {
        for (app in APPS) for (p in app.packages) put(p, app)
    }

    private val BY_ID: Map<NavSourceId, NavApp> = APPS.associateBy { it.id }

    /** Every recognised nav-app package — the notification listener's allow-list. */
    val ALL_PACKAGES: Set<String> = BY_PACKAGE.keys

    fun forPackage(pkg: String?): NavApp? = pkg?.let { BY_PACKAGE[it] }

    fun idFor(pkg: String?): NavSourceId = forPackage(pkg)?.id ?: NavSourceId.UNKNOWN

    fun displayName(id: NavSourceId): String = BY_ID[id]?.displayName ?: id.name

    /** TTL map for the arbiter (per known app; arbiter falls back for the rest). */
    val TTL_MS: Map<NavSourceId, Long> = APPS.associate { it.id to it.ttlMs }
}
