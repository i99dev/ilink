package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.domain.NavFix
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.ingest.NavLocationCache
import com.i99dev.ilink.nav.logic.NavGuidanceCoalescer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TASK-004 — the position CARRIER. Covers the injected-clock throttle, the
 * "no fix / no permission" no-op path, and the load-bearing invariant that
 * position never triggers a push on its own.
 *
 * NOT covered by any test here (pending on-car verification): whether a real BYD
 * head unit actually returns a usable `getLastKnownLocation` for GPS/network,
 * and whether the app holds the location permission on a given car.
 */
class NavLocationTest {

    private fun frame(dist: Int? = 100, road: String = "Main St") = NavGuidance(
        maneuverIcon = 3,
        distanceMeters = dist,
        roadName = road,
        remainingDistanceMeters = 1_000,
        remainingTimeSeconds = 120,
        source = NavSourceId.GOOGLE_MAPS,
    )

    // ---- throttle -----------------------------------------------------------

    @Test
    fun `first call reads immediately`() {
        var reads = 0
        val now = 10_000L
        val cache = NavLocationCache({ reads++; NavFix(25.2, 55.3) }, { now })
        assertNotNull(cache.current())
        assertEquals(1, reads)
    }

    @Test
    fun `reads at most once per 5s and serves cache in between`() {
        var reads = 0
        var now = 0L
        // Each real read returns a distinguishable latitude: 25.1, 25.2, 25.3, …
        val cache = NavLocationCache({ reads++; NavFix(25.0 + reads / 10.0, 55.0) }, { now })

        assertEquals(25.1, cache.current()!!.lat, 1e-9)
        assertEquals(1, reads)

        // Everything inside the window is served from cache, unchanged.
        now = 4_999L
        repeat(50) { cache.current() }
        assertEquals(1, reads)
        assertEquals(25.1, cache.current()!!.lat, 1e-9)

        // Exactly at the boundary the throttle opens.
        now = 5_000L
        assertEquals(25.2, cache.current()!!.lat, 1e-9)
        assertEquals(2, reads)

        now = 9_999L
        cache.current()
        assertEquals(2, reads)
        now = 10_000L
        cache.current()
        assertEquals(3, reads)
    }

    @Test
    fun `reset forces the next call to read again`() {
        var reads = 0
        val now = 0L
        val cache = NavLocationCache({ reads++; NavFix(1.0, 2.0) }, { now })
        cache.current()
        cache.current()
        assertEquals(1, reads)
        cache.reset()
        // Clock has NOT moved, yet reset() must still re-open the throttle.
        cache.current()
        assertEquals(2, reads)
    }

    // ---- no fix / no permission = strict no-op -------------------------------

    @Test
    fun `null reader yields null forever and never throws`() {
        var now = 0L
        val cache = NavLocationCache({ null }, { now })
        assertNull(cache.current())
        now = 60_000L
        assertNull(cache.current())
    }

    @Test
    fun `a throwing reader is swallowed`() {
        val cache = NavLocationCache({ throw SecurityException("no permission") }, { 0L })
        assertNull(cache.current())
    }

    @Test
    fun `a transient empty read keeps the previous fix`() {
        var now = 0L
        var give = true
        val cache = NavLocationCache({ if (give) NavFix(25.0, 55.0) else null }, { now })
        assertNotNull(cache.current())
        give = false
        now = 5_000L
        assertEquals(25.0, cache.current()!!.lat, 1e-9)
    }

    @Test
    fun `withPosition of null leaves the frame identical`() {
        val f = frame()
        assertSame(f, f.withPosition(null))
        assertNull(f.lat)
        assertNull(f.lon)
        assertNull(f.heading)
        assertFalse(f.hasPosition)
    }

    @Test
    fun `withPosition stamps all three fields`() {
        val f = frame().withPosition(NavFix(25.2048, 55.2708, 90.0))
        assertEquals(25.2048, f.lat!!, 1e-9)
        assertEquals(55.2708, f.lon!!, 1e-9)
        assertEquals(90.0, f.heading!!, 1e-9)
        assertTrue(f.hasPosition)
        // and nothing else moved
        assertEquals(frame().copy(lat = f.lat, lon = f.lon, heading = f.heading), f)
    }

    // ---- plausibility --------------------------------------------------------

    @Test
    fun `null island and out-of-range fixes are implausible`() {
        assertFalse(NavFix(0.0, 0.0).isPlausible)
        assertFalse(NavFix(91.0, 10.0).isPlausible)
        assertFalse(NavFix(10.0, 181.0).isPlausible)
        assertTrue(NavFix(25.2048, 55.2708).isPlausible)
    }

    // ---- criterion 3: position must NOT push --------------------------------

    @Test
    fun `moving position alone never pushes a frame`() {
        val c = NavGuidanceCoalescer()
        assertNotNull(c.next(frame().withPosition(NavFix(25.0, 55.0)), keyframe = true))
        // 200 position-only updates — a parked car with a drifting fix.
        repeat(200) { i ->
            val drifted = frame().withPosition(NavFix(25.0 + i * 1e-5, 55.0 + i * 1e-5, i.toDouble()))
            assertNull("position drift #$i must not push", c.next(drifted))
        }
        // A real content change still pushes, carrying whatever position it has.
        val pushed = c.next(frame(road = "Sheikh Zayed Rd").withPosition(NavFix(25.1, 55.1)))
        assertNotNull(pushed)
        assertEquals(25.1, pushed!!.lat!!, 1e-9)
    }
}
