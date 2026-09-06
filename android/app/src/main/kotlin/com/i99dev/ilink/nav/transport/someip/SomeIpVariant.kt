package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavGuidance

/**
 * A SOME/IP wire *variant*: the per-car answer to "which service do I start, and
 * which (topic, payload) events does one nav frame become?".
 *
 * This is the seam only. [SomeIpHudTransport][com.i99dev.ilink.nav.transport.SomeIpHudTransport]
 * still owns everything Android: bind, the raw-binder `transact` codes, the
 * callback binder, lifecycle. A variant owns nothing but bytes.
 *
 * The reference (2.4.2.1) split its single payload builder into three strategy
 * implementations for the same reason. [Ui7Variant] is the one we already ship,
 * lifted out of the transport verbatim; the other two are **not** ported.
 *
 * Contract:
 *  - **Pure.** Zero Android imports. Same inputs → same bytes, always. That is
 *    what makes the wire host-JVM testable (`NavSomeIpVariantTest`) instead of
 *    only checkable on a car.
 *  - Implementations must not cache mutable per-frame state; the controller
 *    already coalesces and stamps [counter].
 */
interface SomeIpVariant {
    /** Stable identity for logs/diagnostics (e.g. "UI7"). */
    val name: String

    /**
     * Service ids this variant needs started/stopped (`transact(4)`/`transact(5)`).
     * A list because other trims start more than one; [Ui7Variant] starts exactly one.
     */
    val serviceIds: List<Long>

    /**
     * Marshal one frame into the events to fire. Pure: `frame` → ordered list of
     * `(topic, payload)`. The transport fires each in order via `transact(6)`.
     * An empty list means "nothing to send for this frame".
     */
    fun buildEvents(frame: NavGuidance, counter: Int): List<Pair<Long, ByteArray>>

    /**
     * The events a `clear()` fires: same wire, "nothing to show" content. On the
     * interface (not just the concrete variant) because the transport clears
     * through this seam too — otherwise `clear()` would have to re-implement the
     * payload and the wire would live in two places again.
     */
    fun buildClearEvents(): List<Pair<Long, ByteArray>>
}
