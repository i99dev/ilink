package com.i99dev.ilink.nav.transport.canfid

import android.os.SystemClock

/**
 * 7.0UI instrument-cluster HUD **wake** state machine, reverse-engineered from a
 * working DiLink 7.0UI cluster HUD.
 *
 * The 7.0UI cluster (Leopard 7 / Ti7) silently **ignores every guidance write
 * until the HUD is woken**: `NAVI_STATUS = NAVI_WAKE_CMD` + `HUD_ENABLE = HUD_ENABLE_ON`.
 * "Awake" is confirmed by reading `NAVI_STATUS` back == `NAVI_ACTIVE`. This is the
 * step our reference-derived sequence was missing — it wrote `NAVI_STATUS = 2` (the
 * *state*, not the wake *command*), so on L7 the typed HAL write "succeeded" while
 * the cluster kept painting the native nav.
 *
 * Ladder: try the raw `service call` **SHELL** form first — it drives the cluster
 * even when the reflected HAL is null — and, if it doesn't verify, fall back to
 * the **TYPED** HAL for the rest of the session. Retry once per frame until
 * verified, then **cache** (skip the handshake thereafter). Cheap and idempotent:
 * the verify short-circuits once awake, and the only process-spawning step (the
 * SHELL exec) runs at most once before the in-process typed fallback.
 *
 * Stateful, so it lives on the long-lived [InstrumentHalWriter] (one per daemon),
 * not on the pure [BydGuidance] sequences. Single-threaded by construction (the
 * daemon serves `halGuide` on one worker), so no locking is needed beyond the
 * volatile publish of [awake].
 *
 * [clockMs] is injectable so the backoff is host-testable without a real clock.
 */
class BydHudWake(private val clockMs: () -> Long = { SystemClock.elapsedRealtime() }) {

    private enum class Mode { SHELL, TYPED, BACKOFF }

    @Volatile private var awake = false
    private var mode = Mode.SHELL
    private var lastTryMs = 0L
    private var attempts = 0

    /** True once the HUD has been verified awake (cheap after the first success). */
    val isAwake: Boolean get() = awake

    /**
     * Ensure the HUD is awake before guidance is written. Idempotent: a no-op once
     * verified; otherwise runs one rung of the SHELL→TYPED ladder and re-checks.
     * Returns the awake state (callers still write guidance regardless — the next
     * frame retries the wake).
     */
    fun ensure(w: FidWriter): Boolean {
        if (awake) return true
        // Backoff: at most one wake attempt per interval regardless of frame rate,
        // so a cluster that never confirms can't spawn a shell per frame. The SHELL
        // (process-spawning) rung runs only on the first attempt; thereafter the
        // in-process typed write retries, then settles into slow re-probe.
        val now = clockMs()
        val interval = if (mode == Mode.BACKOFF) BACKOFF_MS else RETRY_MS
        if (now - lastTryMs < interval) return false
        lastTryMs = now
        when (mode) {
            Mode.SHELL -> {
                BydGuidance.wakeShell(w)
                if (BydGuidance.isHudAwake(w)) {
                    awake = true
                    return true
                }
                // SHELL didn't verify — fall back to the typed HAL for this session.
                mode = Mode.TYPED
                BydGuidance.wakeTyped(w)
            }
            Mode.TYPED, Mode.BACKOFF -> BydGuidance.wakeTyped(w)
        }
        awake = BydGuidance.isHudAwake(w)
        if (!awake && mode == Mode.TYPED && ++attempts >= MAX_TYPED_ATTEMPTS) {
            mode = Mode.BACKOFF // stop per-second churn on a stubborn cluster
        }
        return awake
    }

    /**
     * Forget the awake state so the next [ensure] re-runs the full SHELL→TYPED
     * handshake. Call on nav-off and on cluster-display loss (ignition/park), when
     * BYD may have reset the cluster.
     */
    fun reset() {
        awake = false
        mode = Mode.SHELL
        lastTryMs = 0L
        attempts = 0
    }

    private companion object {
        const val RETRY_MS = 1_000L // ≤1 wake attempt/sec (matches the keepalive)
        const val BACKOFF_MS = 10_000L // slow re-probe once a cluster is deemed stubborn
        const val MAX_TYPED_ATTEMPTS = 5 // ~5s of typed retries, then slow re-probe
    }
}
