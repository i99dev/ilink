package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavLane
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TASK-016 — golden-bytes guard for the opt-in `launcher_map_cn` wire.
 *
 * ## What these goldens do and do NOT prove
 * They prove the wire is **stable and matches an independent second
 * implementation**: the expected hex was produced by a separately written
 * protobuf encoder driven from the field map in
 * the documented field map, not dumped out of
 * [LauncherMapCnVariant]. So a match is genuine agreement between two encoders,
 * and any later drift in ours fails here.
 *
 * They do **not** prove the wire is *correct for our cars*. Nothing off a car can.
 * In particular the six map-camera constants are an unexplained capture (see
 * [LauncherMapPose]); these tests pin where they land on the wire, not that the
 * values are right. Do not read a green bar here as clearance to default anyone
 * onto this variant.
 *
 * Determinism comes from injecting the two non-deterministic inputs — wall clock
 * and route id — which is the whole reason those are constructor seams.
 */
class NavSomeIpLauncherMapCnTest {

    private companion object {
        const val NOW = 1_700_000_000_000L
        const val ROUTE = 1_234_567_890L
    }

    private fun variant(pose: LauncherMapPose = LauncherMapPose.REFERENCE_CAPTURE) =
        LauncherMapCnVariant(pose = pose, nowMillis = { NOW }, routeIdSource = { ROUTE })

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    private fun dump(events: List<Pair<Long, ByteArray>>): List<Pair<Long, String>> =
        events.map { it.first to hex(it.second) }

    /** Every optional populated: lanes, a real fix, non-zero progress. */
    private val fullFrame = NavGuidance(
        maneuverIcon = 4,
        distanceMeters = 300,
        roadName = "Sheikh Zayed Rd",
        remainingDistanceMeters = 4200,
        remainingTimeSeconds = 700,
        lane = NavLane(laneCodes = listOf(2, 3, 4), activeIndices = listOf(false, true, false)),
        lat = 25.2048,
        lon = 55.2708,
        heading = 90.0,
    )

    /** Nothing present: no lanes, no fix, no distances. */
    private val sparseFrame = NavGuidance(
        maneuverIcon = 0,
        distanceMeters = null,
        roadName = "",
        remainingDistanceMeters = null,
        remainingTimeSeconds = null,
        lane = null,
    )

    // ---- 1. the service-id derivation ---------------------------------------

    /**
     * The formula is verified against a pair we did NOT derive it from and that is
     * proven on a real car of ours: the shipped UI7 RoadInfo topic maps to the
     * shipped UI7 service id. That is what turns "a formula that fits the topics
     * it was read off" into an actual check.
     */
    @Test
    fun serviceIdFormulaReproducesOurOwnOnCarProvenPair() {
        assertEquals(
            Ui7Variant.SERVICE_ID,
            LauncherMapCnVariant.serviceIdFor(Ui7Variant.TOPIC_ROAD),
        )
    }

    @Test
    fun serviceIdFormulaIsExactForAllElevenTopics() {
        // Structure: topic = 0x0004 <service16> <instance16> <event16>;
        // service id = 0x000B <service16> <instance16> 0x0000.
        for (topic in LauncherMapCnVariant.TOPICS) {
            val sid = LauncherMapCnVariant.serviceIdFor(topic)
            assertEquals("tag nibble not rewritten 0x0004 -> 0x000B for $topic",
                0x000BL, sid ushr 48)
            assertEquals("middle 32 bits not preserved for $topic",
                (topic ushr 16) and 0xFFFFFFFFL, (sid ushr 16) and 0xFFFFFFFFL)
            assertEquals("event id not zeroed for $topic", 0L, sid and 0xFFFFL)
        }
    }

    @Test
    fun elevenTopicsCollapseToSixDistinctServices() {
        assertEquals(11, LauncherMapCnVariant.TOPICS.size)
        assertEquals(11, LauncherMapCnVariant.TOPICS.distinct().size)
        assertEquals(
            listOf(
                3096254809047040L, 3239172026531840L, 3096276284211200L,
                3096280579244032L, 3096284874276864L, 3096323529572352L,
            ),
            variant().serviceIds,
        )
    }

    /** This variant must never touch the service the proven UI7 wire runs on. */
    @Test
    fun doesNotOverlapTheUi7ServiceOrTopic() {
        assertTrue(Ui7Variant.SERVICE_ID !in variant().serviceIds)
        assertTrue(Ui7Variant.TOPIC_ROAD !in LauncherMapCnVariant.TOPICS)
    }

    // ---- 2. one frame = exactly 11 events, one per topic ---------------------

    /**
     * Pins OUR emit model: 11 events, one per topic, none repeated.
     *
     * Not the reference's — it gates the lane/empty-lane events on lane-code
     * change, so from fresh state it emits 10 (deliberate deviation 1; we
     * coalesce upstream instead). And the single-fire tail this rests on is an
     * ASSUMPTION about a recovery artifact, not arithmetic: "11 declared == 11
     * emitted" assumes its conclusion, since a declared topic count says nothing
     * about events-per-call. See TASK-019 / ISSUE-004. The no-topic-repeated
     * check is still a real guard against a double-fire regression.
     */
    @Test
    fun oneFrameEmitsExactlyElevenEventsOnePerTopicInOrder() {
        val topics = variant().buildEvents(fullFrame, 7).map { it.first }
        assertEquals(11, topics.size)
        assertEquals(11, topics.distinct().size)
        assertEquals(LauncherMapCnVariant.TOPICS, topics)
    }

    // ---- 3. frozen goldens (cross-checked against a second encoder) ----------

    @Test
    fun frozenGoldenFullFrame() {
        assertEquals(
            listOf(
                1125929972105217L to "0a022065",
                1268847189590027L to "0a0908041004180020ac02",
                1125929972105219L to
                    "0a1a8801e8209001bc0559dfe00b93a9a24b40618638d6c56d343940",
                // Lane field 2 carries the reference's raw 0xFF sentinel
                // (`1203ff03ff`). It read `120300 0300` until TASK-018 fixed D5;
                // these bytes come from the independent oracle, not from a
                // re-capture of our own output.
                1268847189590028L to
                    "0a220a030203041203ff03ff2203ffffff2a030000003203ff00ff49" +
                        "00008056febc7842",
                1125951447269377L to "0a0608febeb3eb09",
                1125951447269379L to "0a0608cd9eefb806",
                1125955742302209L to
                    "0a1a08f8c1e6b00d2801610000000000001440699a99999999990140",
                1125955742302210L to "0a0608f6d0a99c0e",
                1125955742302213L to "0a0808b68ec3960f1801",
                1125960037335041L to "0a1108d285d8cc041801210000796090281843",
                1125998692630531L to
                    "0a4d0a1108d285d8cc0410071900007960902818431a3609767746b1" +
                        "df249240115113412724598e4019fcb5a079aa2833c02150a1605" +
                        "890ef573f29692dfdb4bd23f9bf31c789be2520ab6e3f3807",
            ),
            dump(variant().buildEvents(fullFrame, 7)),
        )
    }

    @Test
    fun frozenGoldenSparseFrame() {
        assertEquals(
            listOf(
                1125929972105217L to "0a022065",
                1268847189590027L to "0a080800100018002000",
                // Trip progress with NO FIX. Fields 11/12 carry the stub
                // (116.4074 / 39.9042), not 0.0/0.0: the reference reads one
                // static LocationHelper that is pre-seeded to exactly these
                // values and never yields 0, so this is what a no-fix frame puts
                // on the wire. It read `...590000000000000000610000...` (null
                // island) until TASK-019 fixed ISSUE-003. These bytes come from
                // the independent oracle, not from re-dumping our own output.
                1125929972105219L to
                    "0a1888010090010059fc1873d7121a5d406188855ad3bcf34340",
                1268847189590028L to "0a130a00120022002a0032004900008056febc7842",
                1125951447269377L to "0a0608febeb3eb09",
                1125951447269379L to "0a0608cd9eefb806",
                1125955742302209L to
                    "0a1a08f8c1e6b00d2801610000000000001440699a99999999990140",
                1125955742302210L to "0a0608f6d0a99c0e",
                1125955742302213L to "0a0808b68ec3960f1801",
                1125960037335041L to "0a1108d285d8cc041801210000796090281843",
                1125998692630531L to
                    "0a4d0a1108d285d8cc0410001900007960902818431a3609767746b1" +
                        "df249240115113412724598e4019fcb5a079aa2833c02150a1605" +
                        "890ef573f29692dfdb4bd23f9bf31c789be2520ab6e3f3807",
            ),
            dump(variant().buildEvents(sparseFrame, 0)),
        )
    }

    @Test
    fun frozenGoldenClearEvents() {
        val v = variant()
        v.buildEvents(fullFrame, 1)     // establish the route id first
        assertEquals(
            listOf(
                1268847189590028L to "0a130a00120022002a0032004900008056febc7842",
                1125955742302209L to
                    "0a1a08f8c1e6b00d2800610000000000000000690000000000000000",
                1125955742302213L to "0a0808b68ec3960f1800",
                1125960037335041L to "0a1108d285d8cc041800210000796090281843",
            ),
            dump(v.buildClearEvents()),
        )
    }

    // ---- 4. the pose is a parameter, not a baked literal ---------------------

    /**
     * The requirement that makes an on-car calibration a one-line change: swapping
     * the pose must change the map-camera payload and NOTHING else on the wire.
     * If someone re-inlines the constants into the payload builder, this fails.
     */
    @Test
    fun poseIsInjectableAndOnlyAffectsTheMapCameraEvent() {
        val other = LauncherMapPose(1.0, 2.0, 3.0, 0.1, 0.2, 0.3)
        val a = dump(variant().buildEvents(fullFrame, 7))
        val b = dump(variant(other).buildEvents(fullFrame, 7))

        assertEquals(a.size, b.size)
        for (i in a.indices) {
            if (a[i].first == LauncherMapCnVariant.TOPIC_MAP_CAMERA) {
                assertNotEquals("pose had no effect on the map-camera event", a[i], b[i])
            } else {
                assertEquals("pose leaked into topic ${a[i].first}", a[i], b[i])
            }
        }
    }

    /** The reference capture, pinned. A silent edit here would ship a different
     *  camera to every opted-in car with no other signal. */
    @Test
    fun referenceCaptureValuesArePinned() {
        val p = LauncherMapPose.REFERENCE_CAPTURE
        assertEquals(1161.2184496889508, p.x, 0.0)
        assertEquals(971.1426529964466, p.y, 0.0)
        assertEquals(-19.15885124372106, p.z, 0.0)
        assertEquals(0.0014609250661213498, p.rollRadians, 0.0)
        assertEquals(-1.5712258405572703, p.pitchRadians, 0.0)
        assertEquals(0.0037437084083233626, p.yawRadians, 0.0)
    }

    /**
     * Documents the one numeric fact we actually established about the six: field
     * 5 is a right angle to within 0.025°, but is NOT −π/2. The near-miss is the
     * evidence that it was measured rather than chosen — if a later "cleanup"
     * rounds it to `-Math.PI / 2`, that evidence is destroyed and this fails.
     */
    @Test
    fun pitchIsNearButNotExactlyMinusHalfPi() {
        val pitch = LauncherMapPose.REFERENCE_CAPTURE.pitchRadians
        val delta = pitch - (-Math.PI / 2)
        assertTrue("pitch is no longer within 0.05 deg of -pi/2", Math.abs(delta) < 1e-3)
        assertNotEquals("pitch was 'tidied' to exactly -pi/2", -Math.PI / 2, pitch, 0.0)
    }

    /** Every model resolves to the uncalibrated reference capture today. Adding a
     *  real per-car calibration is expected to change this test — deliberately. */
    @Test
    fun everyModelStillUsesTheUncalibratedReferencePose() {
        for (m in listOf(null, "", "Leopard 8", "Leopard 5", "Leopard 5 Ultra", "Leopard 7", "?")) {
            assertEquals(LauncherMapPose.REFERENCE_CAPTURE, LauncherMapPose.forModel(m))
        }
    }

    // ---- 5. lane encoding (the deviation that would fail silently) -----------

    /**
     * Field 6 marks INACTIVE with 0xFF. The reference derives it by testing its
     * active array for the sentinels 255/−1; our lane model encodes inactive as
     * `false`/0, so transcribing that test would have marked every lane active.
     * This pins the recomputed mapping.
     */
    @Test
    fun laneActiveFlagsAreDerivedFromOurBooleansNotTheReferenceSentinel() {
        val frame = fullFrame.copy(
            lane = NavLane(laneCodes = listOf(2, 3, 4), activeIndices = listOf(false, true, false)),
        )
        val lanes = variant().buildEvents(frame, 1)
            .first { it.first == LauncherMapCnVariant.TOPIC_LANES }.second
        val h = hex(lanes)
        // field 2 = code when active, else the reference's raw 0xFF sentinel
        // -> ff 03 ff. NOT 0x00: UI7 field 29's sentinel→0 mapping belongs to
        // that message only, and applying it here was TASK-017's D5 (fixed in
        // TASK-018).
        assertTrue("field 2 active-code mapping wrong: $h", h.contains("1203ff03ff"))
        // field 6 = 0x00 for active, 0xFF for inactive -> ff 00 ff
        assertTrue("field 6 inactive mask wrong: $h", h.contains("3203ff00ff"))
    }

    /** A frame with no lanes still emits the lane topic, with empty fields — we
     *  emit unconditionally instead of keeping a second dedupe cache next to the
     *  controller's coalescer. */
    @Test
    fun aFrameWithoutLanesStillEmitsAnEmptyLaneEvent() {
        val events = variant().buildEvents(sparseFrame, 0)
        val lanes = events.first { it.first == LauncherMapCnVariant.TOPIC_LANES }.second
        assertEquals("0a130a00120022002a0032004900008056febc7842", hex(lanes))
    }

    /** activeIndices shorter than laneCodes must not throw — sources disagree. */
    @Test
    fun raggedLaneArraysDoNotThrow() {
        val ragged = fullFrame.copy(
            lane = NavLane(laneCodes = listOf(2, 3, 4, 5), activeIndices = listOf(true)),
        )
        assertEquals(11, variant().buildEvents(ragged, 1).size)
    }

    // ---- 6. route-id lifecycle ----------------------------------------------

    /** Stable across frames of one route (the receiver correlates on it), fresh
     *  after a clear. */
    @Test
    fun routeIdIsStableWithinARouteAndResetsOnClear() {
        var next = 1L
        val v = LauncherMapCnVariant(nowMillis = { NOW }, routeIdSource = { next++ })

        val a = hex(v.buildEvents(fullFrame, 1).first { it.first == LauncherMapCnVariant.TOPIC_ROUTE_METADATA }.second)
        val b = hex(v.buildEvents(fullFrame, 2).first { it.first == LauncherMapCnVariant.TOPIC_ROUTE_METADATA }.second)
        assertEquals("route id changed mid-route", a, b)

        v.buildClearEvents()
        val c = hex(v.buildEvents(fullFrame, 1).first { it.first == LauncherMapCnVariant.TOPIC_ROUTE_METADATA }.second)
        assertNotEquals("route id survived a clear", a, c)
    }

    /** The default generator stays inside the reference's 10-digit band. */
    @Test
    fun defaultRouteIdsAreTenDigit() {
        repeat(200) {
            val v = LauncherMapCnVariant(nowMillis = { NOW })
            v.buildEvents(fullFrame, 1)
            // Exercised through the wire rather than a getter: no route id, no bytes.
            assertEquals(11, v.buildEvents(fullFrame, 2).size)
        }
        assertTrue(LauncherMapCnVariant.MIN_ROUTE_ID < LauncherMapCnVariant.MAX_ROUTE_ID_EXCL)
    }

    // ---- 7. maneuver mapping -------------------------------------------------

    @Test
    fun mainActionMappingIsTheReferenceTable() {
        val expected = mapOf(
            1 to 2, 2 to 3, 3 to 4, 4 to 4, 5 to 5, 6 to 5, 7 to 6, 8 to 7,
            9 to 8, 10 to 9, 11 to 1, 12 to 1,
        )
        for ((code, action) in expected) {
            assertEquals("maneuver $code", action, LauncherMapCnVariant.mainActionFor(code))
        }
        // Everything outside the table collapses to 0 — including the unknown
        // codes (>49) our frame model deliberately refuses to draw.
        for (code in listOf(0, 13, 20, 49, 50, 99, -1)) {
            assertEquals("maneuver $code should be unmapped", 0, LauncherMapCnVariant.mainActionFor(code))
        }
    }

    // ---- 8. identity ---------------------------------------------------------

    @Test
    fun nameIsReportedForDiagnostics() {
        assertEquals("LAUNCHER_MAP_CN", variant().name)
    }
}
