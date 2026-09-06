package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.NavTextNormalizer
import com.i99dev.ilink.nav.logic.RoadNameCache
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host-JVM coverage for the centralized text-normalization choke ([NavTextNormalizer])
 * and the persisted-options holder ([NavHudOptions]).
 *
 * NOTE: the ICU `Any-Latin` transliteration (Arabic/Cyrillic → Latin) and the Amap
 * broadcast Intent extras are Android-only — verified on-car (Gate D), not here.
 * Host exercises the JDK fallback path (diacritics) + the wiring/gating contracts.
 */
class NavOptionsNormalizerTest {

    private fun frame(road: String, secondary: String = "") = NavGuidance(
        maneuverIcon = 1,
        distanceMeters = 200,
        roadName = road,
        remainingDistanceMeters = 5_000,
        remainingTimeSeconds = 600,
        secondaryRoadName = secondary,
        source = NavSourceId.GOOGLE_MAPS,
    )

    // ---- NavTextNormalizer ----

    @Test
    fun disabledReturnsSameInstance() {
        val f = frame("Café")
        assertSame("disabled must not allocate/alter", f, NavTextNormalizer.apply(f, enabled = false))
    }

    @Test
    fun enabledFoldsDiacriticsOnBothRoadFields() {
        val out = NavTextNormalizer.apply(frame("Café", "Peña"), enabled = true)
        assertEquals("Cafe", out.roadName)
        assertEquals("Pena", out.secondaryRoadName)
    }

    @Test
    fun enabledPreservesCjkAndTrims() {
        val out = NavTextNormalizer.apply(frame("  北京路  "), enabled = true)
        assertEquals("北京路", out.roadName)
    }

    @Test
    fun enabledNoChangeReturnsSameInstance() {
        // Pure-ASCII already-clean text → sanitize is a no-op → no needless copy.
        val f = frame("Main St")
        assertSame(f, NavTextNormalizer.apply(f, enabled = true))
    }

    // ---- NavHudOptions (in-memory contract; persistence is Android) ----

    @After
    fun restoreDefaults() {
        NavHudOptions.set("transliterate", true)
        NavHudOptions.set("cameraAlerts", true)
        NavHudOptions.set("amapWidget", true)
        NavHudOptions.set("autoStart", true)
    }

    @Test
    fun defaultsMatchSpec() {
        assertTrue(NavHudOptions.transliterate)
        assertTrue(NavHudOptions.amapWidget)
        assertEquals(4, NavHudOptions.snapshot().size)
    }

    @Test
    fun setMutatesAndSnapshotReflects() {
        NavHudOptions.set("amapWidget", false)
        assertFalse(NavHudOptions.amapWidget)
        assertEquals(false, NavHudOptions.snapshot()["amapWidget"])
    }

    @Test
    fun unknownKeyIsIgnored() {
        NavHudOptions.set("nope", true)
        assertFalse(NavHudOptions.snapshot().containsKey("nope"))
    }

    // ---- RoadNameCache (anti-flicker road retention) ----

    @Test
    fun roadCacheRetainsLastNonBlankWithinWindow() {
        val c = RoadNameCache(retainMs = 1_000L)
        assertEquals("Main St", c.resolve("Main St", 0))
        // blank within the window → retained
        assertEquals("Main St", c.resolve("", 500))
        // blank past the window → drops to blank
        assertEquals("", c.resolve("", 1_600))
    }

    @Test
    fun roadCacheTakesFreshNonBlankAndResets() {
        val c = RoadNameCache(retainMs = 1_000L)
        c.resolve("Main St", 0)
        assertEquals("Elm Rd", c.resolve("Elm Rd", 100)) // newer name wins immediately
        c.reset()
        assertEquals("", c.resolve("", 200)) // nothing retained after reset
    }
}
