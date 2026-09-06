package com.i99dev.ilink.nav.transport

import com.i99dev.ilink.nav.domain.NavGuidance

/**
 * A swappable cluster-HUD output. Mirrors the reference's `HudOutputStrategy`:
 * keyed by a stable [name] (the controller caches the active one by identity),
 * an availability [probe], idempotent [start], clear-on-[stop], and the
 * [push] hot path. Implementations marshal the canonical [NavGuidance] into
 * their own wire — none of them leak per-app/per-car logic up to the controller.
 *
 * Order of preference (decided per car by [probe], not hard-wired):
 *  - [com.i99dev.ilink.nav.transport.SomeIpHudTransport] — in-process bind, ADB-free (M0-gated).
 *  - [com.i99dev.ilink.nav.transport.CanFidHudTransport]  — BYD HAL via the privileged daemon (the path the reference proves).
 */
interface HudTransport {
    /** Stable identity used by the controller to cache/compare the active transport. */
    val name: String

    /** Cheap probe: can this transport reach the cluster on THIS car right now? */
    fun isAvailable(): Boolean

    /** Is the transport actually LINKED right now (e.g. SOME/IP service bound)?
     *  Distinct from [isAvailable] (can it be selected). Drives the on-car
     *  diagnostics so the M0 bind-from-app-uid result is visible. Defaults to
     *  [isAvailable] for stateless transports. */
    fun connected(): Boolean = isAvailable()

    /** Idempotent activate (bind / open / turn navi on). */
    fun start()

    /** Deactivate and clear the cluster (unbind / navi off). Resets internal state. */
    fun stop()

    /**
     * Push a frame. The controller has already coalesced (only real deltas
     * arrive) and stamped a rolling [counter]. Implementations must not block
     * the caller for I/O beyond the single binder round-trip.
     */
    fun push(frame: NavGuidance, counter: Int)

    /** Clear the maneuver from the cluster without tearing the transport down. */
    fun clear()
}

/**
 * Per-maneuver rendering shared across transports, injected so the 49-icon
 * cache + the synthetic guide-line + the formatters live in ONE place instead
 * of being duplicated per transport. The real implementation is wired from the
 * extracted ground truth (icon-draw spec, `guideLine` algorithm, `ym0` distance
 * format); [NoopHudRenderer] is the graceful default until then.
 */
interface HudRenderer {
    /** 128×128 ARGB PNG for the SOME/IP payload (field 8). Empty → omit the icon. */
    fun iconPng(maneuverCode: Int): ByteArray

    /** HAL/Amap integer icon code for the maneuver (CAN-FID / Amap transports). */
    fun iconCode(maneuverCode: Int): Int

    /**
     * The field-30 poly-line string for SOME/IP, projected from the car's real
     * position when the frame carries one.
     *
     * [lat]/[lon]/[heading] are the frame's own (nullable) position — pass them
     * straight through; do NOT read location here. Null/implausible means "no
     * fix / no permission" and MUST fall back to the previous, position-free
     * output. Defaulted so a renderer that has no use for position stays simple.
     */
    fun guideLine(
        maneuverCode: Int,
        lat: Double? = null,
        lon: Double? = null,
        heading: Double? = null,
    ): String

    /** Human ETA string (field 26), e.g. "12 min". "" → omit. */
    fun formatEta(remainingSeconds: Int?): String
}

/** Safe no-op renderer: empty icon, empty guide-line, minute-rounded ETA. The
 *  transport stays correct (graceful) until the real renderer is injected. */
object NoopHudRenderer : HudRenderer {
    override fun iconPng(maneuverCode: Int): ByteArray = ByteArray(0)
    override fun iconCode(maneuverCode: Int): Int = maneuverCode
    override fun guideLine(maneuverCode: Int, lat: Double?, lon: Double?, heading: Double?): String = "[]"
    override fun formatEta(remainingSeconds: Int?): String =
        remainingSeconds?.takeIf { it >= 0 }?.let { "${(it + 59) / 60} min" } ?: ""
}
