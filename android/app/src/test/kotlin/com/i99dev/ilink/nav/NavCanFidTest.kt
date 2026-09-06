package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.transport.canfid.BydFid
import com.i99dev.ilink.nav.transport.canfid.BydGuidance
import com.i99dev.ilink.nav.transport.canfid.FidCanFidSink
import com.i99dev.ilink.nav.transport.canfid.FidWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Host-JVM coverage for the CAN-FID guidance write-sequences (HAL injected). */
class NavCanFidTest {

    /** Records every FID write in order for assertion. */
    private class RecordingWriter(var naviStatus: Int = 4) : FidWriter {
        data class W(val kind: String, val fid: Int, val value: Int, val bytes: ByteArray? = null)
        val writes = mutableListOf<W>()
        override fun instrumentInt(fid: Int, value: Int) { writes += W("i", fid, value) }
        override fun instrumentBytes(fid: Int, value: ByteArray) { writes += W("b", fid, 0, value) }
        override fun settingInt(fid: Int, value: Int) { writes += W("s", fid, value) }
        override fun instrumentRead(fid: Int): Int = naviStatus
        override fun cameraGuidance(type: Int, distanceMeters: Int, state: Int) { writes += W("cam", type, distanceMeters) }
        override fun safeGuidance(type: Int, distanceMeters: Int, state: Int) { writes += W("safe", type, distanceMeters) }
    }

    @Test
    fun simpleGuidanceWritesIconDualDist() {
        val w = RecordingWriter()
        BydGuidance.sendSimpleGuidanceInfo(w, icon = 7, dist = 300)
        assertEquals(
            listOf(
                Triple("i", BydFid.GUIDE_ICON, 7),
                Triple("i", BydFid.GUIDE_DUAL_ICON, 7),
                Triple("i", BydFid.GUIDE_DIST, 300),
            ),
            w.writes.map { Triple(it.kind, it.fid, it.value) },
        )
    }

    @Test
    fun laneGuidanceWritesCountTwelveSlotsThenDist() {
        val w = RecordingWriter()
        BydGuidance.sendLaneGuidanceInfo(w, intArrayOf(2, 3), dist = 120)
        // LANE_NUM=2, then 12 slots (first 2 = codes, rest = 255), then LANE_DIST
        assertEquals(BydFid.LANE_NUM, w.writes.first().fid)
        assertEquals(2, w.writes.first().value)
        val slots = w.writes.subList(1, 13)
        assertEquals(2, slots[0].value)
        assertEquals(3, slots[1].value)
        assertTrue("empty slots are 255", slots.drop(2).all { it.value == BydFid.LANE_EMPTY })
        assertEquals(BydFid.LANE_DIST, w.writes.last().fid)
        assertEquals(120, w.writes.last().value)
    }

    @Test
    fun turnOnWritesWakeHandshake() {
        val w = RecordingWriter()
        BydGuidance.turnOnNavi(w)
        // 7.0UI wake (typed): instrument NAVI_STATUS = NAVI_ACTIVE (2), then setting
        // NAVI_SCREEN_STATUS = NAVI_SCREEN_ON (3). The verify + SHELL fallback live
        // in BydHudWake; this is the underlying write sequence.
        assertEquals(Triple("i", BydFid.NAVI_STATUS, BydFid.NAVI_ACTIVE), w.writes[0].let { Triple(it.kind, it.fid, it.value) })
        assertEquals(Triple("s", BydFid.NAVI_SCREEN_STATUS, BydFid.NAVI_SCREEN_ON), w.writes[1].let { Triple(it.kind, it.fid, it.value) })
    }

    @Test
    fun tripInfoSplitsTimeAndClampsRanges() {
        val w = RecordingWriter()
        BydGuidance.sendTripInfo(w, remainingTimeSeconds = 3 * 3600 + 25 * 60 + 40, remainingDistanceMeters = 12_500)
        val byFid = w.writes.associate { it.fid to it.value }
        assertEquals(3, byFid[BydFid.TRIP_HOUR])
        assertEquals(25, byFid[BydFid.TRIP_MINUTE])
        assertEquals(12_500, byFid[BydFid.TRIP_MILEAGE])

        val big = RecordingWriter()
        BydGuidance.sendTripInfo(big, remainingTimeSeconds = 999 * 3600, remainingDistanceMeters = 50_000_000)
        val byFidBig = big.writes.associate { it.fid to it.value }
        assertEquals(254, byFidBig[BydFid.TRIP_HOUR]) // clamped 0..254
        assertEquals(9_999_000, byFidBig[BydFid.TRIP_MILEAGE]) // clamped 0..9_999_000
    }

    @Test
    fun turnOffClearsEveryRegister() {
        val w = RecordingWriter()
        BydGuidance.turnOffNavi(w)
        val byFid = w.writes.associate { it.fid to it.value }
        assertEquals(BydFid.NAVI_STOPPED, byFid[BydFid.NAVI_STATUS])
        assertEquals(0, byFid[BydFid.GUIDE_ICON])
        assertEquals(-1, byFid[BydFid.GUIDE_DIST])
        assertEquals(-1, byFid[BydFid.TRIP_MILEAGE])
        // road name cleared via empty bytes
        assertTrue(w.writes.any { it.kind == "b" && it.fid == BydFid.NEXT_PATHNAME_BYTES && it.bytes?.isEmpty() == true })
    }

    @Test
    fun cameraAndSafetyGuidanceRouteToSdk() {
        val w = RecordingWriter()
        BydGuidance.sendCameraGuidanceInfo(w, type = 1, distanceMeters = 200, state = 0)
        BydGuidance.clearCamera(w)
        BydGuidance.sendSafeGuidanceInfo(w, type = 1, distanceMeters = 150, state = 0)
        assertEquals(listOf("cam", "cam", "safe"), w.writes.map { it.kind })
        assertEquals(1, w.writes[0].fid)    // camera type recorded in fid slot
        assertEquals(200, w.writes[0].value) // distance in value slot
        assertEquals(0, w.writes[1].fid)    // clearCamera type=0
    }

    @Test
    fun sinkReportsHalAbsentWhenNoWriter() {
        assertFalse(FidCanFidSink(null).isHalPresent())
        assertTrue(FidCanFidSink(RecordingWriter()).isHalPresent())
    }

    @Test
    fun ensureNaviActiveReArmsOnlyWhenInactive() {
        val active = RecordingWriter(naviStatus = BydFid.NAVI_ACTIVE)
        FidCanFidSink(active).ensureNaviActive()
        assertTrue("already active → no writes", active.writes.isEmpty())

        val stopped = RecordingWriter(naviStatus = BydFid.NAVI_STOPPED)
        FidCanFidSink(stopped).ensureNaviActive()
        assertTrue("inactive → re-arm (turnOnNavi writes)", stopped.writes.isNotEmpty())
    }
}
