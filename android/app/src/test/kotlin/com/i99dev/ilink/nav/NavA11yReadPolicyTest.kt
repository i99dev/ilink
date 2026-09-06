package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.ingest.NavA11yReadPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host coverage for the a11y nav read POLICY — and only the policy.
 *
 * WHAT THIS PROVES: the three pure decisions the background-ingest fix rests on —
 * the cheap package gate, the root-ownership check, and the cost gate that sits in
 * front of the all-displays enumeration.
 *
 * WHAT THIS CANNOT PROVE (do not read a green run as more than it is): the
 * accessibility ladder itself. `getWindowsOnAllDisplays()`, `AccessibilityWindowInfo.root`,
 * `AccessibilityNodeInfo.getParent()/getWindow()` and `rootInActiveWindow` have no host-JVM
 * implementation — there is no AccessibilityService on a host JVM, so no test here executes
 * a single line of `RemoteControlAccessibilityService.onAccessibilityEvent`,
 * `rootFromEvent` or `readBackgroundNavWindows`. Nor can a host test observe whether a BYD
 * ROM preserves FLAG_RETRIEVE_INTERACTIVE_WINDOWS, or whether a backgrounded map keeps a
 * readable window at all. All of that is pending on-car verification.
 */
class NavA11yReadPolicyTest {

    private val maps = "com.google.android.apps.maps"
    private val active = setOf(maps, "com.waze")

    // ---- cheap gate (the perf guard we must NOT lose) --------------------------------

    @Test
    fun navEventOnlyForRegisteredPackages() {
        assertTrue(NavA11yReadPolicy.isNavEvent(maps, active))
        assertTrue(NavA11yReadPolicy.isNavEvent("com.waze", active))
        // The whole point of the guard: an unrelated app's content-change events must
        // decide "no" here and never reach any node-tree work.
        assertFalse(NavA11yReadPolicy.isNavEvent("com.byd.launcher", active))
        assertFalse(NavA11yReadPolicy.isNavEvent("com.android.systemui", active))
    }

    @Test
    fun navEventFalseWhenNothingArmedOrNoPackage() {
        assertFalse(NavA11yReadPolicy.isNavEvent(maps, emptySet()))
        assertFalse(NavA11yReadPolicy.isNavEvent(null, active))
        assertFalse(NavA11yReadPolicy.isNavEvent(null, emptySet()))
    }

    // ---- root ownership (the starvation fix) -----------------------------------------

    @Test
    fun rootMatchesOnlyItsOwnPackage() {
        assertTrue(NavA11yReadPolicy.rootMatches(maps, maps))
        // The regression this closes: a backgrounded map's event used to dispatch the
        // FOREGROUND app's tree under the map's package name. It yielded no frame but
        // still burned the source's 200 ms throttle, which could throttle out the poll's
        // correct background read.
        assertFalse(NavA11yReadPolicy.rootMatches("com.byd.launcher", maps))
        assertFalse(NavA11yReadPolicy.rootMatches("com.waze", maps))
    }

    @Test
    fun rootMatchesRejectsUnknownOwner() {
        assertFalse(NavA11yReadPolicy.rootMatches(null, maps))
        assertFalse(NavA11yReadPolicy.rootMatches(maps, null))
        assertFalse(NavA11yReadPolicy.rootMatches(null, null))
    }

    // ---- cost gate (in FRONT of the enumeration) --------------------------------------

    @Test
    fun scanGateAllowsFirstCallThenRateLimits() {
        val gate = NavA11yReadPolicy.ScanGate(minIntervalMs = 200L)
        assertTrue("first scan must always pass", gate.allow(1_000L))
        assertFalse(gate.allow(1_001L))
        assertFalse(gate.allow(1_199L))
        assertTrue("exactly at the interval is allowed", gate.allow(1_200L))
        assertFalse(gate.allow(1_399L))
        assertTrue(gate.allow(1_400L))
    }

    @Test
    fun scanGateRearmsFromTheAllowedCallNotTheDeniedOne() {
        val gate = NavA11yReadPolicy.ScanGate(minIntervalMs = 200L)
        assertTrue(gate.allow(0L))
        // A burst of denied calls must not push the next allowed instant out; otherwise a
        // high event rate could starve the scan indefinitely — which is the exact class of
        // bug this fix exists to remove.
        repeat(10) { assertFalse(gate.allow(50L + it)) }
        assertTrue(gate.allow(200L))
    }

    @Test
    fun scanGateSurvivesABackwardClock() {
        val gate = NavA11yReadPolicy.ScanGate(minIntervalMs = 200L)
        assertTrue(gate.allow(10_000L))
        // now < last must not underflow into a permanent deny.
        assertTrue(gate.allow(5L))
        assertFalse(gate.allow(6L))
    }

    @Test
    fun scanGateDefaultIntervalMatchesTheReferenceCadence() {
        // The reference throttles its per-app read to 200 ms BEFORE calling its ladder,
        // so the enumeration itself is what is rate-limited. Ours must sit in the same
        // position at the same cadence.
        assertEquals(200L, NavA11yReadPolicy.SCAN_MIN_INTERVAL_MS)
        val gate = NavA11yReadPolicy.ScanGate()
        assertTrue(gate.allow(0L))
        assertFalse(gate.allow(199L))
        assertTrue(gate.allow(200L))
    }

    @Test
    fun parentWalkIsBounded() {
        // A malformed or cyclic node tree must not spin the a11y thread.
        assertTrue(NavA11yReadPolicy.MAX_PARENT_WALK in 1..1024)
    }
}
