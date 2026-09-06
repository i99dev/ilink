package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavLane
import com.i99dev.ilink.nav.transport.HudRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TASK-017 — **differential test against an independent re-implementation of the
 * OpenBYD 2.4.2.1 SOME/IP encoders.**
 *
 * ## Why this exists
 * No car is available, so the on-car gate cannot be run. This substitutes the
 * strongest hardware-free evidence obtainable: our emitted wire bytes are
 * compared against what the reference implementation — which IS on-car proven —
 * would emit for the same input frame.
 *
 * The expected bytes in `test/resources/nav/someip/openbyd-differential-vectors.tsv`
 * were produced by a **separately written Python encoder**, transcribed from the
 * decompiled reference and never from our Kotlin. A golden captured from the code
 * under test proves only that the code equals itself; agreement between two
 * independently written encoders is real evidence.
 *
 * ## The ordering that makes this credible — do not reorder
 * The oracle was validated **first** against [Ui7Variant], whose wire is on-car
 * proven and whose goldens in `NavSomeIpVariantTest` were captured pre-refactor.
 * It reproduced all five byte-for-byte before a single `launcher_map_cn` verdict
 * was read. [oracleIsValidatedAgainstTheOnCarProvenUi7Wire] re-runs that gate here
 * so it can never silently stop holding. If UI7 and the oracle ever disagree, the
 * **oracle** is wrong — UI7 is the side with hardware evidence behind it.
 *
 * ## What a green bar here CLOSES
 * Protocol transcription fidelity: topic set, emit order, payload byte layout,
 * field numbers, wire types, varint encoding, sentinel handling, envelope framing,
 * event counts.
 *
 * ## What it does NOT close — say this out loud, every time
 * Whether the six [LauncherMapPose] map-camera constants produce a correct view on
 * an L8 or an L5 LR. A byte match reproduces the reference's constants *exactly*,
 * **including any per-car calibration baked into them**. That risk is completely
 * untouched by this file. Nothing here promotes any commit to "verified";
 * everything that was pending on-car before is pending on-car after.
 *
 * ## Field 8 — a DELIBERATE divergence, excluded on purpose
 * Field 8 of the UI7 RoadInfo message is a runtime-rendered maneuver icon PNG. We
 * draw our own glyphs; the reference loads BYD's assets. **Those bytes differ by
 * design and on legal grounds, and we do not import their assets.** So field 8 is
 * compared by *presence and length-prefix framing* only, never by content — see
 * [normalizeIconContent] and the two tests that prove the exclusion is real
 * ([iconContentIsExcludedFromByteEqualityButFramingIsNot],
 * [iconFramingRegressionIsStillCaught]).
 */
class NavSomeIpDifferentialTest {

    // ---------------------------------------------------------------------
    // 0. fixture plumbing
    // ---------------------------------------------------------------------

    /** One generated vector: the input frame plus the bytes the oracle demands. */
    private data class Vector(
        val kind: String,
        val name: String,
        val counter: Int,
        val frame: NavGuidance,
        val events: List<Pair<Long, String>>,
    )

    private companion object {
        const val RESOURCE = "/nav/someip/openbyd-differential-vectors.tsv"
        const val NOW = 1_700_000_000_000L
        const val ROUTE = 1_234_567_890L

        /** Deterministic renderer — byte-for-byte the one the oracle modelled. */
        val FakeRenderer: HudRenderer = object : HudRenderer {
            override fun iconPng(maneuverCode: Int): ByteArray =
                if (maneuverCode in 1..49) byteArrayOf(1, 2, 3) else ByteArray(0)
            override fun iconCode(maneuverCode: Int): Int = maneuverCode
            override fun guideLine(
                maneuverCode: Int,
                lat: Double?,
                lon: Double?,
                heading: Double?,
            ): String = if (maneuverCode in 1..49) "[[0,0],[1,1]]" else "[]"
            override fun formatEta(remainingSeconds: Int?): String =
                remainingSeconds?.takeIf { it >= 0 }?.let { "${(it + 59) / 60} min" } ?: ""
        }
    }

    private val lines: List<String> by lazy {
        val stream = javaClass.getResourceAsStream(RESOURCE)
            ?: error("vector fixture missing from the test classpath: $RESOURCE")
        stream.bufferedReader(Charsets.UTF_8).readLines()
    }

    private fun consts(): Map<String, String> = lines
        .filter { it.startsWith("#CONST ") }
        .associate {
            val parts = it.removePrefix("#CONST ").split(" ", limit = 2)
            parts[0] to parts[1]
        }

    private fun vectors(kind: String): List<Vector> = lines
        .filterNot { it.startsWith("#") || it.isBlank() }
        .map { it.split('\t') }
        .filter { it[0] == kind }
        .map { c ->
            val codes = c[8].takeIf { it.isNotEmpty() }?.split(',')?.map(String::toInt)
            val active = c[9].takeIf { it.isNotEmpty() }?.split(',')?.map { f -> f == "1" }
            Vector(
                kind = c[0],
                name = c[1],
                counter = c[2].toInt(),
                frame = NavGuidance(
                    maneuverIcon = c[3].toInt(),
                    distanceMeters = c[4].nullableInt(),
                    roadName = c[7],
                    remainingDistanceMeters = c[5].nullableInt(),
                    remainingTimeSeconds = c[6].nullableInt(),
                    lane = codes?.let { NavLane(it, active.orEmpty()) },
                    lat = c[10].nullableDouble(),
                    lon = c[11].nullableDouble(),
                ),
                events = c[12].split(';').map { e ->
                    val (topic, hex) = e.split(':')
                    topic.toLong() to hex
                },
            )
        }

    private fun String.nullableInt(): Int? = if (this == "~") null else toInt()
    private fun String.nullableDouble(): Double? = if (this == "~") null else toDouble()

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String): ByteArray =
        ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    // ---------------------------------------------------------------------
    // 1. a minimal protobuf reader — so field NUMBERS and ORDER are asserted
    //    structurally, not just as an opaque hex blob
    // ---------------------------------------------------------------------

    private data class PbField(val number: Int, val wireType: Int, val value: ByteArray)

    private fun parseFields(msg: ByteArray): List<PbField> {
        val out = ArrayList<PbField>()
        var i = 0
        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                val b = msg[i++].toInt() and 0xFF
                result = result or ((b and 0x7F).toLong() shl shift)
                if (b and 0x80 == 0) return result
                shift += 7
            }
        }
        while (i < msg.size) {
            val tag = varint()
            val number = (tag ushr 3).toInt()
            val wire = (tag and 7L).toInt()
            val start = i
            when (wire) {
                0 -> { varint() }
                1 -> { i += 8 }
                2 -> { val len = varint().toInt(); val s = i; i += len
                       out.add(PbField(number, wire, msg.copyOfRange(s, i))); continue }
                5 -> { i += 4 }
                else -> error("unsupported wire type $wire for field $number")
            }
            out.add(PbField(number, wire, msg.copyOfRange(start, i)))
        }
        return out
    }

    /** Strips the envelope (outer field 1, wire-type 2) off an event payload. */
    private fun innerOf(payload: ByteArray): ByteArray {
        val outer = parseFields(payload)
        assertEquals("envelope must be exactly one field", 1, outer.size)
        assertEquals("envelope field number must be 1", 1, outer[0].number)
        assertEquals("envelope must be length-delimited", 2, outer[0].wireType)
        return outer[0].value
    }

    /**
     * Replaces field 8's CONTENT with a canonical fill of the same length,
     * preserving the field's presence, its number, its wire type and its
     * length prefix. This is what "compare the icon by framing, not content"
     * means concretely — the framing survives the normalisation, the pixels
     * do not.
     */
    private fun normalizeIconContent(payload: ByteArray): String {
        val fields = parseFields(innerOf(payload))
        return fields.joinToString("|") { f ->
            val v = if (f.number == 8) "<icon:${f.value.size}B>" else hex(f.value)
            "${f.number}/${f.wireType}=$v"
        }
    }

    // ---------------------------------------------------------------------
    // 2. THE GATE: validate the oracle against the on-car-proven UI7 wire
    //    before trusting any of its LauncherMapCn verdicts
    // ---------------------------------------------------------------------

    /**
     * The oracle's UI7 vectors must reproduce our shipped wire exactly. Our UI7
     * bytes are on-car proven (3.15.0-b) and independently confirmed identical to
     * the reference's UI7 strategy, so this is a held-out trusted pair: the oracle
     * has hardware evidence to answer to, not the other way round.
     *
     * A failure here means the ORACLE is wrong and must be fixed. It is NOT
     * licence to edit the variant.
     */
    @Test
    fun oracleIsValidatedAgainstTheOnCarProvenUi7Wire() {
        val vs = vectors("ui7")
        assertTrue("expected a substantial UI7 matrix, got ${vs.size}", vs.size >= 40)

        val failures = StringBuilder()
        for (v in vs) {
            val events = Ui7Variant(FakeRenderer).buildEvents(v.frame, v.counter)
            if (events.size != v.events.size) {
                failures.append("\n  ${v.name}: emitted ${events.size} events, " +
                    "oracle says ${v.events.size}")
                continue
            }
            for (i in events.indices) {
                val (topic, bytes) = events[i]
                val (expTopic, expHex) = v.events[i]
                if (topic != expTopic) {
                    failures.append("\n  ${v.name}[$i]: topic $topic != $expTopic")
                }
                // Icon CONTENT excluded, icon FRAMING included.
                val ours = normalizeIconContent(bytes)
                val theirs = normalizeIconContent(unhex(expHex))
                if (ours != theirs) {
                    failures.append("\n  ${v.name}[$i]:\n    ours   $ours\n    oracle $theirs")
                }
            }
        }
        assertEquals(
            "ORACLE/UI7 DISAGREEMENT — fix the ORACLE, not the variant. UI7 is the " +
                "side with on-car evidence.$failures",
            "", failures.toString(),
        )
    }

    /** clear() is part of the wire too — the reference sends a blank RoadInfo. */
    @Test
    fun ui7ClearMatchesTheOracle() {
        val v = vectors("ui7clear").single()
        val events = Ui7Variant(FakeRenderer).buildClearEvents()
        assertEquals(v.events.size, events.size)
        assertEquals(v.events[0].first, events[0].first)
        assertEquals(
            normalizeIconContent(unhex(v.events[0].second)),
            normalizeIconContent(events[0].second),
        )
    }

    // ---------------------------------------------------------------------
    // 3. the icon exclusion is REAL, and the framing check still bites
    // ---------------------------------------------------------------------

    /**
     * Proves the exclusion is not decorative: a renderer emitting *different*
     * icon pixels of the same length produces different RAW bytes but the same
     * normalised comparison. That is exactly the property the exclusion claims.
     */
    @Test
    fun iconContentIsExcludedFromByteEqualityButFramingIsNot() {
        val frame = vectors("ui7").first { it.name == "lane_mixed" }
        val ourIcon = Ui7Variant(FakeRenderer).buildEvents(frame.frame, frame.counter)[0].second
        val otherPixels = object : HudRenderer by FakeRenderer {
            override fun iconPng(maneuverCode: Int): ByteArray =
                if (maneuverCode in 1..49) byteArrayOf(9, 9, 9) else ByteArray(0)
        }
        val theirIcon = Ui7Variant(otherPixels).buildEvents(frame.frame, frame.counter)[0].second

        assertNotEquals("fixture is degenerate: the two icons are identical",
            hex(ourIcon), hex(theirIcon))
        assertEquals("icon CONTENT must not affect the normalised comparison",
            normalizeIconContent(ourIcon), normalizeIconContent(theirIcon))
        assertTrue("field 8 must still be present and framed",
            normalizeIconContent(ourIcon).contains("8/2=<icon:3B>"))
    }

    /**
     * The other half: a length change IS a framing change and must be caught.
     * Without this, "we excluded the icon" would quietly excuse a broken
     * length prefix — the exact failure mode this wire cannot report.
     */
    @Test
    fun iconFramingRegressionIsStillCaught() {
        val frame = vectors("ui7").first { it.name == "lane_mixed" }
        val baseline = Ui7Variant(FakeRenderer).buildEvents(frame.frame, frame.counter)[0].second
        val longerIcon = object : HudRenderer by FakeRenderer {
            override fun iconPng(maneuverCode: Int): ByteArray =
                if (maneuverCode in 1..49) ByteArray(200) { 7 } else ByteArray(0)
        }
        val changed = Ui7Variant(longerIcon).buildEvents(frame.frame, frame.counter)[0].second
        assertNotEquals("a different icon LENGTH must change the framed comparison",
            normalizeIconContent(baseline), normalizeIconContent(changed))

        // ...and an icon that disappears entirely must drop field 8, not send an
        // empty one (the reference gates on `length != 0`).
        val noIcon = object : HudRenderer by FakeRenderer {
            override fun iconPng(maneuverCode: Int): ByteArray = ByteArray(0)
        }
        val without = normalizeIconContent(
            Ui7Variant(noIcon).buildEvents(frame.frame, frame.counter)[0].second)
        assertTrue("field 8 must be OMITTED when the icon is empty, not sent empty",
            !without.contains("8/2="))
    }

    // ---------------------------------------------------------------------
    // 4. only NOW: the launcher_map_cn verdicts
    // ---------------------------------------------------------------------

    private fun launcherVariant() = LauncherMapCnVariant(
        pose = LauncherMapPose.REFERENCE_CAPTURE,
        nowMillis = { NOW },
        routeIdSource = { ROUTE },
    )

    /**
     * The whole matrix, byte-equal. No icon field on this wire, so nothing is
     * excluded here at all — this is unconditional byte equality.
     */
    @Test
    fun launcherMapCnMatchesTheOracleByteForByte() {
        val vs = vectors("lmc")
        assertTrue("expected a substantial matrix, got ${vs.size}", vs.size >= 20)
        val failures = StringBuilder()
        for (v in vs) {
            val events = launcherVariant().buildEvents(v.frame, v.counter)
            if (events.size != v.events.size) {
                failures.append("\n  ${v.name}: ${events.size} events != ${v.events.size}")
                continue
            }
            for (i in events.indices) {
                if (events[i].first != v.events[i].first) {
                    failures.append("\n  ${v.name}[$i]: topic ${events[i].first} " +
                        "!= ${v.events[i].first}")
                }
                if (hex(events[i].second) != v.events[i].second) {
                    failures.append("\n  ${v.name}[$i] topic ${v.events[i].first}:" +
                        "\n    ours   ${hex(events[i].second)}" +
                        "\n    oracle ${v.events[i].second}")
                }
            }
        }
        assertEquals("launcher_map_cn diverges from the oracle:$failures", "",
            failures.toString())
    }

    /** The stop sequence, likewise. */
    @Test
    fun launcherMapCnClearMatchesTheOracle() {
        val v = vectors("lmcclear").single()
        // routeId must exist before clear() can close it, same as on a car.
        val variant = launcherVariant()
        variant.buildEvents(vectors("lmc").first().frame, 1)
        val events = variant.buildClearEvents()
        assertEquals(v.events.size, events.size)
        for (i in events.indices) {
            assertEquals("clear[$i] topic", v.events[i].first, events[i].first)
            assertEquals("clear[$i] bytes", v.events[i].second, hex(events[i].second))
        }
    }

    /**
     * **All 11 topics, by COUNT and by ORDER.**
     *
     * Read this as pinning OUR emit model, not as measuring the reference's
     * (TASK-019 / ISSUE-004b). Two things were previously overstated here:
     *
     * 1. *The count is ours.* The reference gates its lane event on a lane-code
     *    change and its empty-lane event on having had lanes, so from a fresh
     *    state it emits **10**, not 11. We emit all 11 every frame because we
     *    coalesce upstream instead — deliberate deviation 1 in
     *    [LauncherMapCnVariant]'s KDoc. This test locks in that choice.
     * 2. *The tail collapse is an assumption.* Read literally the decompiled tail
     *    fires 3 + 1 + 7 + 7 = 18 events and repeats 7 topics; we collapse it to
     *    one firing. "11 declared == 11 emitted settles it arithmetically" does
     *    NOT follow — a declared topic count constrains nothing about
     *    events-per-call, so the two 11s are different quantities. The collapse
     *    is very probably right, but only the reference's own on-car stream
     *    settles it.
     *
     * What the test still genuinely enforces: the declared topic set is ours
     * exactly, topics are distinct, and no topic fires twice — which is the
     * duplicated-tail regression guard, and that part is worth keeping.
     */
    @Test
    fun launcherMapCnEmitsElevenTopicsOncePerFrameInDeclaredOrder() {
        val declared = consts()["launcherMapTopics"]!!.split(',').map(String::toLong)
        assertEquals("the reference declares 11 topics", 11, declared.size)
        assertEquals("declared topics must be distinct", 11, declared.toSet().size)
        assertEquals("our TOPICS list must be the declared set, in order",
            declared, LauncherMapCnVariant.TOPICS)

        for (v in vectors("lmc")) {
            val topics = launcherVariant().buildEvents(v.frame, v.counter).map { it.first }
            assertEquals("${v.name}: event count != declared topic count", 11, topics.size)
            assertEquals("${v.name}: a topic fired twice (duplicated-tail regression)",
                11, topics.toSet().size)
            assertEquals("${v.name}: emit order != declared order", declared, topics)
        }
    }

    /** Service-id derivation, cross-checked against the on-car-proven UI7 pair. */
    @Test
    fun serviceIdsMatchTheOracle() {
        val c = consts()
        assertEquals(c["launcherMapServiceIds"]!!.split(',').map(String::toLong).sorted(),
            launcherVariant().serviceIds.sorted())
        assertEquals(c["ui7ServiceId"]!!.toLong(), Ui7Variant.SERVICE_ID)
        assertEquals(c["ui7TopicRoad"]!!.toLong(), Ui7Variant.TOPIC_ROAD)
        // the derivation, applied to a topic from a DIFFERENT, on-car-proven strategy
        assertEquals(Ui7Variant.SERVICE_ID,
            LauncherMapCnVariant.serviceIdFor(Ui7Variant.TOPIC_ROAD))
    }

    /** The six unexplained constants land where the oracle says, bit for bit. */
    @Test
    fun mapCameraPoseMatchesTheOracleBitForBit() {
        val expected = consts()["launcherMapPose"]!!.split(',').map(String::toDouble)
        val p = LauncherMapPose.REFERENCE_CAPTURE
        val ours = listOf(p.x, p.y, p.z, p.rollRadians, p.pitchRadians, p.yawRadians)
        for (i in expected.indices) {
            assertEquals(
                "map-camera field ${i + 1} differs from the reference capture",
                java.lang.Double.doubleToLongBits(expected[i]),
                java.lang.Double.doubleToLongBits(ours[i]),
            )
        }
        // ...and the byte-equality above already proves they land in fields 1..6
        // of the map-camera submessage. What NONE of this proves is that they are
        // right for OUR cars — see the class KDoc.
    }

    // ---------------------------------------------------------------------
    // 5. the sentinel re-derivation (Rule 6) — pinned so a naive transcription
    //    of the reference would fail here
    // ---------------------------------------------------------------------

    /**
     * The reference marks a lane inactive with the sentinels 255 / −1 in a
     * parallel *code* array. Our [NavLane] carries booleans, so transcribing that
     * test verbatim would have marked **every** lane active — it compiles, it
     * passes shape tests, and it is wrong on a car.
     *
     * This asserts the re-derivation on both wires at once: an inactive lane must
     * read ",0" in UI7's field 29 and 0xFF in launcher_map_cn's field 6.
     *
     * Note what is being re-derived: the **test** for inactivity, not the
     * **encoding** of it. UI7 field 29 maps the sentinel to 0; launcher_map_cn
     * lane field 2 keeps it raw. Those two conventions genuinely differ, and
     * assuming they agreed is what produced D5 — see
     * [launcherMapLaneField2PreservesTheReferencesInactiveSentinel].
     */
    @Test
    fun inactiveLanesAreRecomputedFromOurBooleansNotTranscribed() {
        val frame = NavGuidance(
            maneuverIcon = 4, distanceMeters = 300, roadName = "Lane Rd",
            remainingDistanceMeters = 4200, remainingTimeSeconds = 700,
            lane = NavLane(listOf(2, 3, 4), listOf(false, true, false)),
        )

        // UI7 field 29: "code,active|" with active == the code only when recommended.
        val ui7 = parseFields(innerOf(
            Ui7Variant(FakeRenderer).buildEvents(frame, 7)[0].second))
        val f29 = ui7.single { it.number == 29 }.value.toString(Charsets.UTF_8)
        assertEquals("2,0|3,3|4,0|", f29)
        assertNotEquals(
            "the naive transcription (every lane active) survived",
            "2,2|3,3|4,4|", f29,
        )

        // launcher_map_cn field 6: 0xFF marks INACTIVE.
        val lmc = launcherVariant().buildEvents(frame, 7)
        val lanes = lmc.single { it.first == LauncherMapCnVariant.TOPIC_LANES }.second
        val f6 = parseFields(innerOf(lanes)).single { it.number == 6 }.value
        assertEquals("ff00ff", hex(f6))
        assertNotEquals("every lane marked active", "000000", hex(f6))
    }

    /**
     * **D5 — RESOLVED in TASK-018. This test was inverted, not deleted.**
     *
     * launcher_map_cn's lane field 2 is the per-lane *recommended-arrow* array.
     * The reference writes it RAW, sentinels intact, so an inactive lane reads
     * `0xFF`. Our port used to write `0x00` there, having applied UI7 field
     * 29's sentinel→0 convention to a different message that does not have it.
     *
     * TASK-017 pinned that deviation rather than fixing it, on the grounds that
     * only a car can say which reading the launcher wants. **That was overruled:
     * carrying a known, unexplained deviation into the on-car session would give
     * a bad render two candidate causes and burn the scarcest resource in the
     * project on an ambiguous result.** The tie was not real either — the
     * reference's encoding has hardware evidence behind it, our `0x00` had none;
     * it was a transcription slip we could name exactly.
     *
     * So this now asserts the bytes **match** the reference, and the assertion
     * that used to forbid `ff03ff` is the one that forbids the old `000300`.
     * **The name changed with the behaviour on purpose:** a test still called
     * `documentedDivergence_…` would convince the next reader that the
     * divergence is current.
     *
     * Field 29 of the UI7 path is **correct as-is and deliberately untouched** —
     * the two messages genuinely differ, which is the whole finding. See
     * [inactiveLanesAreRecomputedFromOurBooleansNotTranscribed], which pins both
     * conventions side by side.
     */
    @Test
    fun launcherMapLaneField2PreservesTheReferencesInactiveSentinel() {
        val frame = NavGuidance(
            maneuverIcon = 4, distanceMeters = 300, roadName = "",
            remainingDistanceMeters = 4200, remainingTimeSeconds = 700,
            lane = NavLane(listOf(2, 3, 4), listOf(false, true, false)),
        )
        val lanes = launcherVariant().buildEvents(frame, 7)
            .single { it.first == LauncherMapCnVariant.TOPIC_LANES }.second
        val f2 = parseFields(innerOf(lanes)).single { it.number == 2 }.value
        assertEquals("the reference's reading: sentinels preserved", "ff03ff", hex(f2))
        assertNotEquals(
            "regressed to the pre-TASK-018 bug (UI7 field 29's mapping applied here)",
            "000300", hex(f2),
        )

        // The sibling field is untouched by the fix: field 6 still flags
        // inactivity the same way, so a receiver reading EITHER field agrees.
        val f6 = parseFields(innerOf(lanes)).single { it.number == 6 }.value
        assertEquals("field 6 must be unaffected by the field-2 fix", "ff00ff", hex(f6))
    }

    /**
     * **DOCUMENTED DIVERGENCE D1 — pinned.**
     *
     * UI7 field 28. We write the RAW maneuver code (1..49), which is reference
     * 2.3.2's behaviour and is what our on-car-proven wire has always sent.
     * Reference 2.4.2.1 changed this to `mapToF28`, collapsing the maneuver to
     * the 4-value vocabulary {1, 2, 3, 9}. 20 of 23 sampled codes differ.
     *
     * We did NOT adopt their newer mapping: our raw-code wire is the one with
     * hardware evidence, and this is a semantic change to an in-service field
     * with no error channel. Pinned here so the choice stays visible.
     */
    @Test
    fun documentedDivergence_ui7Field28CarriesTheRawManeuverCode() {
        for (code in listOf(1, 4, 7, 9, 10, 15, 49)) {
            val frame = NavGuidance(
                maneuverIcon = code, distanceMeters = 100, roadName = "",
                remainingDistanceMeters = null, remainingTimeSeconds = null,
            )
            val fields = parseFields(innerOf(
                Ui7Variant(FakeRenderer).buildEvents(frame, 1)[0].second))
            val f28 = fields.single { it.number == 28 }.value
            // varint, and every sampled code is < 128 so one byte
            assertEquals("field 28 must carry the raw code $code",
                code, f28[0].toInt() and 0xFF)
        }
        // The 2.4.2.1 mapping would have collapsed 4 -> 3 and 49 -> 1.
        val collapsed = NavGuidance(
            maneuverIcon = 4, distanceMeters = 100, roadName = "",
            remainingDistanceMeters = null, remainingTimeSeconds = null,
        )
        val f28 = parseFields(innerOf(
            Ui7Variant(FakeRenderer).buildEvents(collapsed, 1)[0].second))
            .single { it.number == 28 }.value
        assertNotEquals("2.4.2.1's mapToF28(4) == 3 was adopted without a decision",
            3, f28[0].toInt() and 0xFF)
    }

    // ---------------------------------------------------------------------
    // 6. field numbers and order, asserted structurally
    // ---------------------------------------------------------------------

    /**
     * The reference's field order is NOT ascending in either message and that is
     * on-hardware proven, so it is reproduced rather than tidied. Asserted as a
     * sequence so a "helpful" reordering fails loudly.
     */
    @Test
    fun fieldOrderMatchesTheReferenceIncludingItsNonAscendingRuns() {
        val full = NavGuidance(
            maneuverIcon = 4, distanceMeters = 300, roadName = "Rd",
            remainingDistanceMeters = 4200, remainingTimeSeconds = 700,
            lane = NavLane(listOf(2, 3), listOf(true, false)),
            lat = 25.2048, lon = 55.2708,
        )
        // UI7 RoadInfo: 2, 8, 9, 10, 16, 19, 20, 26, 28, 30, 31, then lanes 5, 29.
        assertEquals(
            listOf(2, 8, 9, 10, 16, 19, 20, 26, 28, 30, 31, 5, 29),
            parseFields(innerOf(Ui7Variant(FakeRenderer).buildEvents(full, 7)[0].second))
                .map { it.number },
        )
        // launcher_map_cn trip progress writes 17, 18, 11, 12 — in that order.
        val trip = launcherVariant().buildEvents(full, 7)
            .single { it.first == LauncherMapCnVariant.TOPIC_TRIP_PROGRESS }.second
        assertEquals(listOf(17, 18, 11, 12), parseFields(innerOf(trip)).map { it.number })
        // map camera: outer 1, 3, 7; inner camera submessage 1..6.
        val cam = launcherVariant().buildEvents(full, 7)
            .single { it.first == LauncherMapCnVariant.TOPIC_MAP_CAMERA }.second
        val outer = parseFields(innerOf(cam))
        assertEquals(listOf(1, 3, 7), outer.map { it.number })
        assertEquals(listOf(1, 2, 3, 4, 5, 6),
            parseFields(outer.single { it.number == 3 }.value).map { it.number })
    }
}
