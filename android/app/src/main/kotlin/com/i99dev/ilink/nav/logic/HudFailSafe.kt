package com.i99dev.ilink.nav.logic

/**
 * The driver-safety state machine for the cluster HUD. A frozen or wrong
 * maneuver on the instrument cluster is a hazard, so EVERY transition has an
 * explicit cluster action. Pure + host-testable; the HudController drives it.
 *
 * States: IDLE → ACTIVE(source) → STALE → (cleared) ; LOST on transport drop.
 * Invariants enforced here:
 *  - first frame after arm / source-switch / reconnect → KEYFRAME (never a
 *    delta against a cluster that may have been cleared);
 *  - winning source goes stale (no fresh frame within its TTL) → CLEAR (never
 *    leave a frozen "turn left" — Waze's TTL is 40 s);
 *  - transport lost → LOST → next frame keyframes on reconnect;
 *  - stop → CLEAR.
 */
class HudFailSafe {

    enum class State { IDLE, ACTIVE, STALE, LOST }

    enum class Action { NONE, PUSH_KEYFRAME, PUSH_DELTA, PUSH_CLEAR }

    var state: State = State.IDLE
        private set

    private var lastFrameMs: Long = 0L
    private var currentTtlMs: Long = 0L

    /** A fresh winning frame for [sourceTtlMs] freshness window. */
    fun onFrame(nowMs: Long, sourceTtlMs: Long): Action {
        lastFrameMs = nowMs
        currentTtlMs = sourceTtlMs
        return if (state == State.ACTIVE) {
            Action.PUSH_DELTA
        } else {
            // IDLE / STALE / LOST → re-arm with a full keyframe
            state = State.ACTIVE
            Action.PUSH_KEYFRAME
        }
    }

    /** Periodic clock tick — clears the cluster when the winning source goes stale. */
    fun onTick(nowMs: Long): Action {
        if (state == State.ACTIVE && nowMs - lastFrameMs > currentTtlMs) {
            state = State.STALE
            return Action.PUSH_CLEAR
        }
        return Action.NONE
    }

    /** Transport binder/HAL dropped — next frame must keyframe on reconnect. */
    fun onTransportLost(): Action {
        state = State.LOST
        return Action.NONE
    }

    /** Navigation ended / HUD disarmed. */
    fun onStop(): Action {
        val wasShowing = state == State.ACTIVE || state == State.STALE
        state = State.IDLE
        return if (wasShowing) Action.PUSH_CLEAR else Action.NONE
    }

    fun reset() {
        state = State.IDLE
        lastFrameMs = 0L
        currentTtlMs = 0L
    }
}
