package com.i99dev.ilink.nav.ingest

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * One nav app's data source. Scrapes a single foreign app (Google Maps / Waze /
 * Yandex) via a11y / notification / MediaProjection and emits canonical
 * [NavGuidance] partials. Adding a nav app = one `NavSource` impl — no edits to
 * the registry, arbiter, controller, or transports.
 *
 * The package set + view-ids a source reads belong to the source (and are
 * injected into the shared a11y handler), never hard-wired into a shared service.
 */
interface NavSource {
    val id: NavSourceId

    /** Freshness window for this source's frames (ground truth: GMaps 5s,
     *  Yandex 10s, Waze 40s). The arbiter/fail-safe use this to drop stale data. */
    val ttlMs: Long

    /** Begin scraping; call [onFrame] each time a (possibly partial) frame is
     *  parsed, and [onGone] when this source detects navigation ended (e.g. its
     *  notification was removed). [onGone] defaults to no-op — sources without an
     *  end signal (a11y) rely on the controller's staleness backstop instead. */
    fun start(onFrame: (NavGuidance) -> Unit, onGone: (NavSourceId) -> Unit = {})

    /** Stop scraping + release any listener/projection. */
    fun stop()
}
