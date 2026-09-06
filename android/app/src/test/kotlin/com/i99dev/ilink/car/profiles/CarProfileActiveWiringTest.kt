package com.i99dev.ilink.car.profiles

import com.i99dev.ilink.miniapps.MiniAppDispatcher
import org.junit.After
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * Regression lock for CarProfile-audit **D1**: `setActive()` had ZERO
 * production callers, so `forActiveCar()` was permanently
 * `GENERIC_PROFILE`. The `pkg.launch` role gate
 * (`DisplayRoles.roleFor()` → `forActiveCar()`) therefore classified
 * displays against Generic (empty `secondaryDisplayOwners`) while the
 * picker used the correctly-resolved `forVariant()` — two divergent
 * profile sources for the same physical display, a prime cause of
 * "mini-apps don't launch" on a resolved trim.
 *
 * The fix wires `CarProfileRegistry.setActive(...)` into
 * `MiniAppDispatcher.setModelIds()` (the single chokepoint the model
 * detector + override path both route through). These tests fail if
 * that wiring is removed.
 *
 * Also pins the Di5.0↔Di5.1 transport-fork matrix
 * (`capabilities.passenger == DishareQuickShare`) that
 * `DisplayLaunchPlanner` reads to skip the role gate on DiShare
 * trims — same spirit as [CarProfileBranchingTest].
 */
class CarProfileActiveWiringTest {

    @After
    fun tearDown() {
        MiniAppDispatcher.resetForTesting()
        CarProfileRegistry.resetActiveForTesting()
    }

    @Test
    fun `setModelIds wires forActiveCar to the resolved trim (D1)`() {
        CarProfileRegistry.resetActiveForTesting()
        // Pre-condition: with no wiring this stayed Generic forever.
        MiniAppDispatcher.setModelIds(listOf("l5"))
        assertEquals(
            "l5",
            CarProfileRegistry.forActiveCar().variantId,
            "forActiveCar() must reflect the resolved trim, not Generic",
        )
        // And it must NOT be the Generic fallback the bug pinned it to.
        assertNotEquals(
            CarProfileRegistry.forVariant(null).variantId,
            CarProfileRegistry.forActiveCar().variantId,
        )
    }

    @Test
    fun `setModelIds resolves Song PLUS (the currently-connected car)`() {
        CarProfileRegistry.resetActiveForTesting()
        MiniAppDispatcher.setModelIds(listOf("song_plus"))
        assertEquals("song_plus", CarProfileRegistry.forActiveCar().variantId)
    }

    @Test
    fun `unknown or empty chain leaves active as Generic`() {
        CarProfileRegistry.resetActiveForTesting()
        MiniAppDispatcher.setModelIds(listOf("unknown"))
        // Generic is the null-variant fallback profile.
        assertNull(CarProfileRegistry.forActiveCar().variantId)
        MiniAppDispatcher.setModelIds(emptyList())
        assertNull(CarProfileRegistry.forActiveCar().variantId)
    }

    @Test
    fun `override path through setModelIds also updates active`() {
        CarProfileRegistry.resetActiveForTesting()
        MiniAppDispatcher.setModelIds(listOf("l8"))
        assertEquals("l8", CarProfileRegistry.forActiveCar().variantId)
        // Simulate a Settings profile-override re-resolving the chain.
        MiniAppDispatcher.setModelIds(listOf("l5"))
        assertEquals(
            "l5",
            CarProfileRegistry.forActiveCar().variantId,
            "active must follow a re-resolve / override, not stick",
        )
    }

    @Test
    fun `Di5_0 vs Di5_1 transport-fork matrix (role-gate-skip contract)`() {
        // DisplayLaunchPlanner skips the role/permission gate ONLY on
        // DiShare trims, i.e. when capabilities.passenger ==
        // DishareQuickShare. If a trim's passenger transport flips,
        // the role-gate-skip behaviour flips with it — pin the matrix
        // so that's a visible PR diff.
        // song_plus joined this group 2026-05-16: same BYD-container
        // OWN_CONTENT_ONLY topology as L5, framework display
        // targeting dropped → DishareQuickShare (header KDoc on
        // SongPlus.kt). The role-gate-skip must now activate for it.
        // L5U removed from this group 2026-05-17: operator-attested
        // Di5.1/XDJA (behaves like L8/L5L) — the prior DishareQuickShare
        // value was an unverified inherited guess. Only the Di5.0/BYD
        // trims (L5 Flagship/Navigator + Song PLUS) skip the role gate.
        for (v in listOf("l5", "song_plus")) {
            assertEquals(
                PassengerTransport.DishareQuickShare,
                CarProfileRegistry.forVariant(v).capabilities.passenger,
                "$v must be DishareQuickShare (role gate skipped → DiShare path)",
            )
        }
        for (v in listOf("l8", "l5u", "l5l")) {
            assertNotEquals(
                PassengerTransport.DishareQuickShare,
                CarProfileRegistry.forVariant(v).capabilities.passenger,
                "$v must NOT be DishareQuickShare (Fission/framework — role gate still runs)",
            )
        }
        // Generic must never be DishareQuickShare either.
        assertNotEquals(
            PassengerTransport.DishareQuickShare,
            CarProfileRegistry.forVariant(null).capabilities.passenger,
        )
    }
}
