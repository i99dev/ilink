package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.ingest.WazeArrowBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Host coverage for the live Waze-arrow bounds holder. Staleness (the
 *  elapsedRealtime window) is exercised on-car; the host clock is constant. */
class WazeArrowBoundsTest {

    @Test
    fun updateAndLatest() {
        WazeArrowBounds.clear()
        assertNull(WazeArrowBounds.latest())
        WazeArrowBounds.update(10, 20, 30, 40)
        val c = WazeArrowBounds.latest()
        assertNotNull(c)
        assertEquals(10, c!!.left)
        assertEquals(20, c.top)
        assertEquals(30, c.width)
        assertEquals(40, c.height)
    }

    @Test
    fun rejectsDegenerateAndOversizedRects() {
        WazeArrowBounds.clear()
        WazeArrowBounds.update(0, 0, 0, 40) // width 0 — ignored
        WazeArrowBounds.update(0, 0, 40, 0) // height 0 — ignored
        WazeArrowBounds.update(0, 0, 5000, 40) // width > 4096 — ignored
        assertNull(WazeArrowBounds.latest())
        WazeArrowBounds.update(0, 0, 40, 40) // valid
        assertNotNull(WazeArrowBounds.latest())
    }

    @Test
    fun clearDrops() {
        WazeArrowBounds.update(1, 2, 3, 4)
        WazeArrowBounds.clear()
        assertNull(WazeArrowBounds.latest())
    }
}
