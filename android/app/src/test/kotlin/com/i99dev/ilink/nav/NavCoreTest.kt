package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavLane
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.HudFailSafe
import com.i99dev.ilink.nav.logic.NavGuidanceCoalescer
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec
import com.i99dev.ilink.nav.logic.SourceArbiter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

/** Host-JVM coverage for the pure Nav-HUD core (no Android, no car). The codec
 *  test decodes the protobuf back and asserts every field matches the reference's
 *  ground-truth buildRoadInfo layout. */
class NavCoreTest {

    // ---- minimal protobuf reader (for the codec assertions) ----

    private class Reader(val b: ByteArray) {
        var i = 0
        fun varint(): Long {
            var r = 0L; var s = 0
            while (true) {
                val x = b[i++].toInt() and 0xFF
                r = r or ((x.toLong() and 0x7F) shl s)
                if (x and 0x80 == 0) break
                s += 7
            }
            return r
        }
        fun bytes(): ByteArray { val n = varint().toInt(); val o = b.copyOfRange(i, i + n); i += n; return o }
        fun fixed64(): Long { var r = 0L; for (k in 0 until 8) r = r or ((b[i++].toLong() and 0xFF) shl (k * 8)); return r }
        fun done() = i >= b.size
    }

    /** Decode {field -> value} from a flat message (varint→Long, len→ByteArray, 64→Double). */
    private fun decode(msg: ByteArray): Map<Int, Any> {
        val r = Reader(msg); val out = HashMap<Int, Any>()
        while (!r.done()) {
            val tag = r.varint(); val field = (tag ushr 3).toInt()
            when ((tag and 7).toInt()) {
                0 -> out[field] = r.varint()
                1 -> out[field] = java.lang.Double.longBitsToDouble(r.fixed64())
                2 -> out[field] = r.bytes()
                else -> error("wiretype")
            }
        }
        return out
    }

    private fun str(m: Map<Int, Any>, f: Int) = String(m[f] as ByteArray, Charsets.UTF_8)

    @Test
    fun varintMatchesProtobuf() {
        fun v(x: Long): List<Int> {
            val o = ByteArrayOutputStream(); SomeIpRoadInfoCodec.writeVarint(o, x)
            return o.toByteArray().map { it.toInt() and 0xFF }
        }
        assertEquals(listOf(0), v(0))
        assertEquals(listOf(1), v(1))
        assertEquals(listOf(0xAC, 0x02), v(300))      // 300 = 0b10_0101100
        assertEquals(listOf(0x80, 0x01), v(128))
    }

    @Test
    fun buildRoadInfoMatchesGroundTruthLayout() {
        val lane = NavLane(laneCodes = listOf(2, 3, 4), activeIndices = listOf(false, true, false))
        val payload = SomeIpRoadInfoCodec.buildRoadInfo(
            counter = 7,
            maneuverCode = 4,
            distanceMeters = 300,
            roadName = "Sheikh Zayed Rd",
            eta = "12 min",
            iconPng = byteArrayOf(1, 2, 3),
            guideLine = "[]",
            lane = lane,
        )
        // envelope: field 1 (tag 0x0A) length-delimited
        assertEquals(0x0A, payload[0].toInt() and 0xFF)
        val env = Reader(payload)
        env.varint() // tag
        val inner = env.bytes()
        val m = decode(inner)

        assertEquals(7L, m[2])                              // counter
        assertEquals(listOf<Byte>(1, 2, 3), (m[8] as ByteArray).toList()) // icon png
        assertEquals(300L, m[9])                            // distance
        assertEquals("Sheikh Zayed Rd", str(m, 10))        // road
        assertEquals(2L, m[16])                             // const
        assertEquals(SomeIpRoadInfoCodec.STUB_LON, m[19] as Double, 1e-9) // lon stub
        assertEquals(SomeIpRoadInfoCodec.STUB_LAT, m[20] as Double, 1e-9) // lat stub
        assertEquals("12 min", str(m, 26))                 // eta
        assertEquals(4L, m[28])                            // maneuver code
        assertEquals("[]", str(m, 30))                     // guideLine
        assertEquals(SomeIpRoadInfoCodec.STUB_POS, str(m, 31)) // const pos
        assertEquals(3L, m[5])                             // lane count
        assertEquals("2,0|3,3|4,0|", str(m, 29))           // lane str: active idx 1 emits the code, others 0
    }

    @Test
    fun buildRoadInfoOmitsOptionalEmptyFields() {
        val m = run {
            val p = SomeIpRoadInfoCodec.buildRoadInfo(0, 1, 0, "x", "", ByteArray(0), "[]", null)
            val r = Reader(p); r.varint(); decode(r.bytes())
        }
        assertFalse("icon omitted when empty", m.containsKey(8))
        assertFalse("eta omitted when empty", m.containsKey(26))
        assertFalse("lane omitted when null", m.containsKey(5))
        assertFalse("lane str omitted when null", m.containsKey(29))
    }

    // ---- SourceArbiter ----

    private fun frame(src: NavSourceId, dist: Int? = 200) =
        NavGuidance(maneuverIcon = 4, distanceMeters = dist, roadName = "r", remainingDistanceMeters = null, remainingTimeSeconds = null, source = src)

    @Test
    fun arbiterPicksPinnedThenMostRecentThenPriority() {
        val now = 100_000L
        val cands = mapOf(
            NavSourceId.WAZE to SourceArbiter.Candidate(frame(NavSourceId.WAZE), now - 1_000),
            NavSourceId.GOOGLE_MAPS to SourceArbiter.Candidate(frame(NavSourceId.GOOGLE_MAPS), now - 100),
        )
        // pinned wins even if older
        assertEquals(NavSourceId.WAZE, SourceArbiter.arbitrate(cands, now, pinned = NavSourceId.WAZE)?.source)
        // else most-recent wins
        assertEquals(NavSourceId.GOOGLE_MAPS, SourceArbiter.arbitrate(cands, now)?.source)
    }

    @Test
    fun arbiterDropsStaleAndNonDrawable() {
        val now = 100_000L
        val cands = mapOf(
            NavSourceId.GOOGLE_MAPS to SourceArbiter.Candidate(frame(NavSourceId.GOOGLE_MAPS), now - 9_000), // > 5s TTL
            NavSourceId.WAZE to SourceArbiter.Candidate(frame(NavSourceId.WAZE, dist = -1), now - 100),      // not drawable
        )
        assertNull(SourceArbiter.arbitrate(cands, now))
    }

    // ---- Coalescer ----

    @Test
    fun coalescerDedupsAndQuantizesDistance() {
        val c = NavGuidanceCoalescer(distanceBucketMeters = 50)
        val base = frame(NavSourceId.WAZE, dist = 320) // bucket 6 (300..349)
        assertNotNull("first frame pushes", c.next(base))
        assertNull("identical → skip", c.next(base))
        assertNull("same 50m bucket (320→310) → skip", c.next(base.copy(distanceMeters = 310)))
        assertNotNull("new bucket (320→290) → push", c.next(base.copy(distanceMeters = 290))) // bucket 5
        assertNotNull("icon change → push", c.next(base.copy(distanceMeters = 290, maneuverIcon = 9)))
        assertNull("source-only change → skip", c.next(base.copy(distanceMeters = 290, maneuverIcon = 9, source = NavSourceId.GOOGLE_MAPS)))
        assertNotNull("keyframe forces push", c.next(base.copy(distanceMeters = 290, maneuverIcon = 9), keyframe = true))
    }

    @Test
    fun coalescerAdaptiveBucketIsFineNearAndCoarseFar() {
        val c = NavGuidanceCoalescer()
        // Near the maneuver (<200m): 10m granularity — a 15m drop the old 50m
        // bucket would have swallowed (the lag) now pushes.
        assertNotNull("first", c.next(frame(NavSourceId.WAZE, dist = 170)))
        assertNotNull("near: 170→155 (≠10m bucket) pushes", c.next(frame(NavSourceId.WAZE, dist = 155)))
        assertNull("near: 155→151 (same 10m bucket) skips", c.next(frame(NavSourceId.WAZE, dist = 151)))
        // Far away (>600m): stays coarse (50m) to keep off the a11y read rate.
        assertNotNull("jump far", c.next(frame(NavSourceId.WAZE, dist = 720)))
        assertNull("far: 720→705 (same 50m bucket) skips", c.next(frame(NavSourceId.WAZE, dist = 705)))
        assertNotNull("far: 720→690 (≠50m bucket) pushes", c.next(frame(NavSourceId.WAZE, dist = 690)))
    }

    @Test
    fun hasDrawableIconSuppressesOutOfRange() {
        assertTrue("1..49 is drawable", frame(NavSourceId.WAZE).copy(maneuverIcon = 4).hasDrawableIcon)
        assertFalse("0 is suppressed", frame(NavSourceId.WAZE).copy(maneuverIcon = 0).hasDrawableIcon)
        assertFalse(">49 is suppressed", frame(NavSourceId.WAZE).copy(maneuverIcon = 99).hasDrawableIcon)
    }

    // ---- Fail-safe ----

    @Test
    fun failSafeKeyframesAndClears() {
        val fs = HudFailSafe()
        val ttl = 5_000L
        assertEquals(HudFailSafe.Action.PUSH_KEYFRAME, fs.onFrame(0, ttl))
        assertEquals(HudFailSafe.State.ACTIVE, fs.state)
        assertEquals(HudFailSafe.Action.PUSH_DELTA, fs.onFrame(1_000, ttl))
        assertEquals(HudFailSafe.Action.NONE, fs.onTick(3_000))       // within ttl
        assertEquals(HudFailSafe.Action.PUSH_CLEAR, fs.onTick(7_000)) // stale → clear
        assertEquals(HudFailSafe.State.STALE, fs.state)
        assertEquals(HudFailSafe.Action.PUSH_KEYFRAME, fs.onFrame(8_000, ttl)) // re-arm
    }

    @Test
    fun failSafeReKeyframesAfterTransportLoss() {
        val fs = HudFailSafe()
        fs.onFrame(0, 5_000)
        fs.onTransportLost()
        assertEquals(HudFailSafe.State.LOST, fs.state)
        assertEquals(HudFailSafe.Action.PUSH_KEYFRAME, fs.onFrame(1_000, 5_000)) // reconnect keyframes
    }

    @Test
    fun failSafeClearsOnStopWhenShowing() {
        val fs = HudFailSafe()
        fs.onFrame(0, 5_000)
        assertEquals(HudFailSafe.Action.PUSH_CLEAR, fs.onStop())
        assertEquals(HudFailSafe.Action.NONE, fs.onStop()) // already idle
    }
}
