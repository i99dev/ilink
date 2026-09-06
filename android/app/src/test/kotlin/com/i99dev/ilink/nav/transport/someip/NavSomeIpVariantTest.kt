package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavLane
import com.i99dev.ilink.nav.transport.HudRenderer
import com.i99dev.ilink.nav.transport.NoopHudRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Golden-bytes guard for the SOME/IP wire.
 *
 * **TASK-002 note — read before editing.** TASK-001 compared [Ui7Variant] against
 * a local *mirror* of `SomeIpHudTransport.push`'s payload construction, because
 * the variant was not yet wired in and there was no single source of truth. That
 * mirror is now **deleted**: the transport builds no payload of its own, it fires
 * exactly what [Ui7Variant] returns, so these bytes ARE the real call site. Do not
 * reintroduce a hand-copied reference implementation — it would only prove the
 * test equals itself.
 *
 * `push` still cannot run on a host JVM (it needs a real `Parcel`/`IBinder`), so
 * the coverage is split:
 *  1. **Frozen goldens** — fixed hex, captured pre-refactor. This is the lock. A
 *     diff here means the wire changed, so never regenerate them to go green.
 *  2. **Structural delegation guard** ([transportDelegatesTheWireToTheVariant]) —
 *     proves the transport really routes through this seam, i.e. that the goldens
 *     above are on the live path and not on a dead parallel one.
 *
 * This wire has no error channel: a wrong topic or a shifted field just makes the
 * L8 cluster render nothing, silently. Hence belt and braces.
 *
 * Scope note: the `transact(6)` Parcel framing (writeInt(1) + topic + 0 + length
 * + bytes) is Android and is NOT covered here — only the topic and the payload.
 * That framing is on-car-verified only.
 */
class NavSomeIpVariantTest {

    /** Deterministic stand-in for DefaultHudRenderer (which is Android-bound). */
    private object FakeRenderer : HudRenderer {
        override fun iconPng(maneuverCode: Int): ByteArray =
            if (maneuverCode in 1..49) byteArrayOf(1, 2, 3) else ByteArray(0)
        override fun iconCode(maneuverCode: Int): Int = maneuverCode
        override fun guideLine(maneuverCode: Int, lat: Double?, lon: Double?, heading: Double?): String =
            if (maneuverCode in 1..49) "[[0,0],[1,1]]" else "[]"
        override fun formatEta(remainingSeconds: Int?): String =
            remainingSeconds?.takeIf { it >= 0 }?.let { "${(it + 59) / 60} min" } ?: ""
    }

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    /** Little-endian IEEE-754 hex, i.e. exactly how the codec writes a double. */
    private fun leDoubleHex(v: Double): String {
        val bits = java.lang.Double.doubleToLongBits(v)
        return (0 until 8).joinToString("") { "%02x".format(((bits shr (it * 8)) and 0xFF).toInt()) }
    }

    // ---- fixtures ----

    /** Full frame: every optional field populated, lane guidance present. */
    private val fullFrame = NavGuidance(
        maneuverIcon = 4,
        distanceMeters = 300,
        roadName = "Sheikh Zayed Rd",
        remainingDistanceMeters = 4200,
        remainingTimeSeconds = 700,
        lane = NavLane(laneCodes = listOf(2, 3, 4), activeIndices = listOf(false, true, false)),
    )

    /** Nulls / absent optionals: no icon, no eta, empty road, no lane. */
    private val sparseFrame = NavGuidance(
        maneuverIcon = 0,
        distanceMeters = null,
        roadName = "",
        remainingDistanceMeters = null,
        remainingTimeSeconds = null,
        lane = null,
    )

    /** Non-drawable distance (isDrawable == false, negative not null). */
    private val nonDrawableFrame = NavGuidance(
        maneuverIcon = 4,
        distanceMeters = -1,
        roadName = "Al Khail Rd",
        remainingDistanceMeters = null,
        remainingTimeSeconds = -1,
        lane = null,
    )

    // ---- 1. on-car-proven constants (a regression here kills the L8 HUD) ----

    @Test
    fun constantsAreTheOnCarProvenIds() {
        assertEquals(3097367205183488L, Ui7Variant.SERVICE_ID)
        assertEquals(1127042368241665L, Ui7Variant.TOPIC_ROAD)
        assertEquals(listOf(3097367205183488L), Ui7Variant().serviceIds)
        assertEquals("UI7", Ui7Variant().name)

        val topics = Ui7Variant(FakeRenderer).buildEvents(fullFrame, 7).map { it.first }
        assertEquals(listOf(1127042368241665L), topics)
    }

    // ---- 2. the transport really routes through this seam ----

    /**
     * Without this, the goldens below could be pinning a variant nobody calls.
     * `push`/`clear` need a real binder, so we assert structurally instead:
     * the transport delegates to the variant AND builds no payload of its own.
     */
    @Test
    fun transportDelegatesTheWireToTheVariant() {
        val src = File("src/main/kotlin/com/i99dev/ilink/nav/transport/SomeIpHudTransport.kt")
        assertTrue("SomeIpHudTransport.kt not found at ${src.absolutePath}", src.isFile)
        val text = src.readText()

        assertTrue(
            "push() no longer delegates to variant.buildEvents — the goldens here " +
                "would stop guarding the live wire",
            text.contains("variant.buildEvents("),
        )
        assertTrue(
            "clear() no longer delegates to variant.buildClearEvents",
            text.contains("variant.buildClearEvents()"),
        )
        assertTrue(
            "start/stop no longer iterate variant.serviceIds",
            text.contains("variant.serviceIds"),
        )
        // The whole point of the seam: bytes live in exactly one place.
        assertFalse(
            "SomeIpHudTransport builds a payload again — the wire has forked; " +
                "move it back into the variant",
            text.contains("SomeIpRoadInfoCodec"),
        )
        // The wire ids are the variant's now, not the transport's.
        assertFalse(
            "SERVICE_ID literal reappeared in SomeIpHudTransport",
            text.contains("${Ui7Variant.SERVICE_ID}L"),
        )
        assertFalse(
            "TOPIC_ROAD literal reappeared in SomeIpHudTransport",
            text.contains("${Ui7Variant.TOPIC_ROAD}L"),
        )
    }

    /** The transport's default variant must stay the on-car-proven UI7 one. */
    @Test
    fun transportDefaultsToUi7Variant() {
        val src = File("src/main/kotlin/com/i99dev/ilink/nav/transport/SomeIpHudTransport.kt")
        assertTrue(
            "SomeIpHudTransport's default variant is no longer Ui7Variant(renderer) — " +
                "every existing call site would change wire shape",
            src.readText().contains("SomeIpVariant = Ui7Variant(renderer)"),
        )
    }

    // ---- 3. frozen goldens: the lock on the real bytes ----

    @Test
    fun frozenGoldenBytes() {
        assertEquals(GOLDEN_FULL, hex(Ui7Variant(FakeRenderer).buildEvents(fullFrame, 7)[0].second))
        assertEquals(GOLDEN_SPARSE, hex(Ui7Variant(FakeRenderer).buildEvents(sparseFrame, 0)[0].second))
        assertEquals(
            GOLDEN_NON_DRAWABLE,
            hex(Ui7Variant(FakeRenderer).buildEvents(nonDrawableFrame, 255)[0].second),
        )
    }

    /**
     * TASK-005. The goldens above are all position-FREE frames, so they double as
     * the no-regression lock: a car with no fix / no location permission still
     * emits the exact pre-TASK-005 wire, Beijing stub and all.
     *
     * This test covers the other branch — a frame carrying a real fix must put
     * that fix on the wire in fields 19/20 (doubles) and 31 (string), and nowhere
     * else. FakeRenderer ignores position, so field 30 is held constant here and
     * the polyline maths is asserted in `NavGuideLineTest` instead.
     */
    @Test
    fun positionedFrameCarriesTheRealFixInFields19_20_31() {
        val positioned = fullFrame.copy(lat = 25.2048, lon = 55.2708, heading = 90.0)
        val bytes = Ui7Variant(FakeRenderer).buildEvents(positioned, 7)[0].second
        val h = hex(bytes)

        // field 31 (tag 0xFA 0x01) — the "lon,lat,0" string, Locale.US formatted.
        val pos = "55.270800,25.204800,0"
        assertTrue(
            "field 31 does not carry the real position (got $h)",
            h.contains(pos.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }),
        )
        assertFalse("Beijing stub position survived on a positioned frame", h.contains(STUB_POS_HEX))

        // fields 19/20 — little-endian IEEE-754 doubles of lon then lat.
        assertTrue("field 19 lon missing", h.contains(leDoubleHex(55.2708)))
        assertTrue("field 20 lat missing", h.contains(leDoubleHex(25.2048)))

        // ...and the stub doubles are gone.
        assertFalse("stub lon 116.4074 still on the wire", h.contains(leDoubleHex(116.4074)))
        assertFalse("stub lat 39.9042 still on the wire", h.contains(leDoubleHex(39.9042)))

        // An implausible fix (null island) is NOT a position: falls back to stub.
        val nullIsland = fullFrame.copy(lat = 0.0, lon = 0.0)
        assertEquals(GOLDEN_FULL, hex(Ui7Variant(FakeRenderer).buildEvents(nullIsland, 7)[0].second))
        // A half-fix (lat only) likewise falls back — never a half-real position.
        val halfFix = fullFrame.copy(lat = 25.2048, lon = null)
        assertEquals(GOLDEN_FULL, hex(Ui7Variant(FakeRenderer).buildEvents(halfFix, 7)[0].second))
    }

    /** One event, on the RoadInfo topic — a second event would double-push on-car. */
    @Test
    fun ui7EmitsExactlyOneRoadInfoEventPerFrame() {
        val events = Ui7Variant(FakeRenderer).buildEvents(fullFrame, 7)
        assertEquals(1, events.size)
        assertEquals(Ui7Variant.TOPIC_ROAD, events[0].first)
    }

    /** clear() fires the same topic with the blank RoadInfo. Frozen, not mirrored. */
    @Test
    fun frozenGoldenClearBytes() {
        val events = Ui7Variant(FakeRenderer).buildClearEvents()
        assertEquals(1, events.size)
        assertEquals(Ui7Variant.TOPIC_ROAD, events[0].first)
        assertEquals(GOLDEN_CLEAR, hex(events[0].second))
    }

    /**
     * The default (no-arg) renderer is [NoopHudRenderer] — same default the
     * transport had before the variant existed. Frozen so it can't silently
     * become a renderer that emits icons/guide-lines.
     */
    @Test
    fun frozenGoldenDefaultRendererBytes() {
        assertEquals(GOLDEN_FULL_NOOP_RENDERER, hex(Ui7Variant().buildEvents(fullFrame, 12)[0].second))
        assertEquals(
            hex(Ui7Variant(NoopHudRenderer).buildEvents(fullFrame, 12)[0].second),
            hex(Ui7Variant().buildEvents(fullFrame, 12)[0].second),
        )
    }

    private companion object {
        /** UTF-8 hex of the baked "116.4074,39.9042,0" field-31 stub. */
        const val STUB_POS_HEX = "3131362e343037342c33392e393034322c30"

        // Captured from the pre-refactor payload construction. Do NOT regenerate
        // these to make a failing test pass — a diff here means the wire changed.
        const val GOLDEN_FULL =
            "0a741007420301020348ac02520f536865696b68205a61796564205264800102" +
                "9901fc1873d7121a5d40a10188855ad3bcf34340d201063132206d696ee0" +
                "0104f2010d5b5b302c305d2c5b312c315d5dfa01123131362e343037342c" +
                "33392e393034322c302803ea010c322c307c332c337c342c307c"
        const val GOLDEN_SPARSE =
            "0a3a1000480052008001029901fc1873d7121a5d40a10188855ad3bcf34340e0" +
                "0100f201025b5dfa01123131362e343037342c33392e393034322c30"
        const val GOLDEN_NON_DRAWABLE =
            "0a5f10ff01420301020348ffffffffffffffffff01520b416c204b6861696c20" +
                "52648001029901fc1873d7121a5d40a10188855ad3bcf34340e00104f201" +
                "0d5b5b302c305d2c5b312c315d5dfa01123131362e343037342c33392e39" +
                "3034322c30"
        // The blank RoadInfo clear() fires. Byte-for-byte equal to GOLDEN_SPARSE
        // (the pre-refactor capture) — an independent confirmation that routing
        // clear() through the variant did not change what goes on the wire.
        const val GOLDEN_CLEAR = GOLDEN_SPARSE

        // fullFrame under the DEFAULT (Noop) renderer: no icon (field 66 absent),
        // guide-line "[]" — i.e. the shape the transport emitted when constructed
        // without an explicit renderer.
        const val GOLDEN_FULL_NOOP_RENDERER =
            "0a64100c48ac02520f536865696b68205a6179656420526480010299" +
                "01fc1873d7121a5d40a10188855ad3bcf34340d201063132206d69" +
                "6ee00104f201025b5dfa01123131362e343037342c33392e393034" +
                "322c302803ea010c322c307c332c337c342c307c"
    }
}
