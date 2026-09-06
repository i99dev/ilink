package com.i99dev.ilink.nav.ingest

import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * The package(s) of the nav app currently DRIVING the cluster, published by
 * [NavSourceRegistry] on every arbitrated winner.
 *
 * **This currently has no reader.** Its consumer was the background-keepalive
 * VirtualDisplay, which `e9835e25` deleted (it relocated single-task maps via
 * `am start --display` and ping-ponged them on-car). Background reads are passive
 * now: the a11y service scans windows that already exist and does not need to be
 * told which app to keep alive. Left in place as a cheap volatile holder; removing
 * it is a separate cleanup.
 *
 * Only the "rich" a11y-scraped apps (Waze / Google Maps / Yandex) map to packages
 * here; notification-driven apps are display-independent and map to an empty list.
 *
 * Thin volatile holder (same shape as the other nav buses) — no Context, no Android.
 */
object NavActiveApp {

    /** Candidate packages for the current rich driver, most-preferred first; empty
     *  when the driver is a notification-only app or nav is idle. */
    @Volatile var richPackages: List<String> = emptyList()
        private set

    fun set(source: NavSourceId) {
        richPackages = when (source) {
            NavSourceId.WAZE -> listOf("com.waze")
            NavSourceId.GOOGLE_MAPS ->
                listOf("com.google.android.apps.maps", "app.revanced.android.apps.maps", "com.gbox.com.google.android.apps.maps")
            NavSourceId.YANDEX -> listOf("ru.yandex.yandexmaps")
            else -> emptyList()
        }
    }

    fun clear() {
        richPackages = emptyList()
    }
}
