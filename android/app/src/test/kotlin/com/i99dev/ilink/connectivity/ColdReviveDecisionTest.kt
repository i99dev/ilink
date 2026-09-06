package com.i99dev.ilink.connectivity

import org.junit.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pure-JVM unit tests for [shouldColdRevive] — the framework-free decision
 * that gates [ConnectivityService.coldReviveIfNeeded]. No Android, no
 * Robolectric: the whole gating contract for the car-start auto-revive is
 * locked in here as a truth table.
 *
 * The three gates and what they protect:
 *   - enabled    : the driver's keep-alive kill-switch (SharedPreferences).
 *   - interactive: car awake / screen on — never spin the SoC up off the
 *                  12V battery while parked.
 *   - running    : our FGS is already resident — never interrupt active use,
 *                  and stay idempotent when onServiceConnected repeat-fires.
 *
 * Revive fires on exactly ONE of the eight combinations: a genuine cold
 * car-start (enabled + awake + previously dead).
 */
class ColdReviveDecisionTest {

    @Test
    fun revivesOnlyOnAwakeDeadProcessWhenEnabled() {
        assertTrue(
            shouldColdRevive(enabled = true, interactive = true, running = false),
            "the one true case: keep-alive on, car awake, process was dead",
        )
    }

    @Test
    fun neverRevivesWhenKeepAliveOff() {
        // Disabled wins over everything — a driver who turned keep-alive off
        // is never auto-revived by ANY vector.
        assertFalse(shouldColdRevive(enabled = false, interactive = true, running = false))
        assertFalse(shouldColdRevive(enabled = false, interactive = false, running = false))
        assertFalse(shouldColdRevive(enabled = false, interactive = true, running = true))
        assertFalse(shouldColdRevive(enabled = false, interactive = false, running = true))
    }

    @Test
    fun neverRevivesWhileParkedScreenOff() {
        // Battery-safe: a non-interactive (parked) wake must never spin up,
        // regardless of the running state.
        assertFalse(shouldColdRevive(enabled = true, interactive = false, running = false))
        assertFalse(shouldColdRevive(enabled = true, interactive = false, running = true))
    }

    @Test
    fun neverRevivesWhenAlreadyRunning() {
        // Idempotent / never interrupt active use — FGS already resident.
        assertFalse(shouldColdRevive(enabled = true, interactive = true, running = true))
    }
}
