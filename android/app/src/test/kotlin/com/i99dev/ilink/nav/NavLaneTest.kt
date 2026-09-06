package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.logic.LaneSegmenter
import com.i99dev.ilink.nav.logic.WazeLaneCapture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Host-JVM coverage for the pure lane-guidance segmentation (P2). */
class NavLaneTest {

    private val WHITE = 0xFFFFFFFF.toInt() // opaque white (max column energy)
    private val CLEAR = 0 // transparent (zero energy; 0x00000000 trips the BYD-id gate)

    /** Build a width×height ARGB row with the given column ranges filled WHITE. */
    private fun row(width: Int, height: Int, vararg bands: IntRange): IntArray {
        val a = IntArray(width * height) { CLEAR }
        for (y in 0 until height) {
            val base = y * width
            for (b in bands) for (x in b) a[base + x] = WHITE
        }
        return a
    }

    @Test
    fun segmentsTwoSeparatedBands() {
        val w = 100; val h = 20
        val argb = row(w, h, 10..30, 60..80) // two 21px bands, 29px gap
        val bands = LaneSegmenter.segment(argb, w, h, density = 1f)
        assertEquals(2, bands.size)
        assertEquals(10, bands[0].left)
        assertEquals(21, bands[0].width)
        assertEquals(60, bands[1].left)
        assertTrue("band carries energy", bands[0].strength > 40f)
    }

    @Test
    fun rejectsTooNarrowBands() {
        // 5px band < 15px minimum → dropped.
        val bands = LaneSegmenter.segment(row(100, 20, 10..14), 100, 20, density = 1f)
        assertTrue(bands.isEmpty())
    }

    @Test
    fun blankRowYieldsNoBands() {
        assertTrue(LaneSegmenter.segment(IntArray(100 * 20), 100, 20, density = 1f).isEmpty())
    }

    @Test
    fun captureIsDegradeSafeWhenUnclassifiable() {
        // Plain white blocks match no arrow signature → fromLaneRow returns null
        // (we never push placeholder lanes that would render wrong arrows).
        val argb = row(100, 20, 10..30, 60..80)
        assertNull(WazeLaneCapture.fromLaneRow(argb, 100, 20, density = 1f))
    }
}
