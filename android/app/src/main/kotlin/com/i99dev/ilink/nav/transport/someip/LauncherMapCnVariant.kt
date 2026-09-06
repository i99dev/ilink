package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavFix
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec.writeBytesField
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec.writeDoubleField
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec.writeVarint
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec.writeVarintField
import java.io.ByteArrayOutputStream
import kotlin.random.Random

/**
 * The **`launcher_map_cn` SOME/IP wire** — a second, opt-in [SomeIpVariant]
 * (TASK-016). Where [Ui7Variant] sends ONE RoadInfo event on ONE topic, this one
 * fans a single nav frame out over **11 topics across 6 service ids**, and drives
 * what the Chinese launcher renders as an embedded **map widget** rather than a
 * text/arrow HUD.
 *
 * ## Status — NOT proven on our cars
 * The mechanism is known-good: the reference implementation ships it and it is
 * tested working on a real vehicle. What is **open** is whether the map-camera
 * constants ([LauncherMapPose]) generalize to L8 UI7 / L5 LR, or are a pose
 * captured from one specific car. That is answerable only on a car.
 *
 * Consequently this variant is **opt-in and never a default** — see
 * [SomeIpVariants.defaultFor], every row of which still answers `ui7`. Selecting
 * it is a deliberate act, and reverting is flipping the option back with no
 * rebuild. A wrong pose degrades gracefully (mis-positioned map view); it does not
 * corrupt guidance, which is what makes it safe to try.
 *
 * ## Wire facts (derived)
 * - **Service id from topic id**, exactly:
 *   `serviceId = (topic and 0x0000FFFFFFFF0000) or 0x000B000000000000`. Verified
 *   against all 11 topics AND — independently — against our own shipped, on-car
 *   proven [Ui7Variant.TOPIC_ROAD] → [Ui7Variant.SERVICE_ID]. See [serviceIdFor].
 * - One frame → **exactly 11 events, one per topic**, in the order below. Note
 *   this is OUR model, not a measured property of the reference: the reference
 *   gates its lane event on a lane-code change and its empty-lane event on
 *   having had lanes before, so from fresh state it emits **10**. We emit all 11
 *   every frame by deliberate choice — see deviation 1.
 * - Field ordering inside a message is **not ascending** (trip progress writes
 *   17, 18, 11, 12). Protobuf tolerates that; the receiver may not. Preserved.
 *
 * ## Deliberate deviations from the reference (each one is a decision, not drift)
 * 1. **No lane-change dedupe.** The reference caches the last lane codes to skip
 *    redundant lane events. We already coalesce upstream —
 *    `NavGuidanceCoalescer` is the SOLE push gate — so a second dedupe here would
 *    be a parallel gate. We emit the lane event every frame (empty when there are
 *    no lanes); it is idempotent.
 * 2. **Lane "inactive" flag is recomputed, not transcribed.** The reference marks
 *    a lane inactive by testing its active-array entry for the sentinels 255/−1.
 *    Our [com.i99dev.ilink.nav.domain.NavLane] carries booleans and encodes
 *    "inactive" as 0, so transcribing that sentinel test would have silently
 *    marked every lane ACTIVE. Field 6 is derived from the boolean directly.
 *    Note this is a re-derivation of the *test*, not of the *encoding*: lane
 *    field 2 still carries the raw `0xFF` sentinel on the wire, because that is
 *    what the reference sends. Recomputing where our model differs and emitting
 *    what the proven wire emits are two separate obligations (TASK-018 / D5).
 * 3. **Single-fire tail — ASSUMED, not proven.** The reference appears to
 *    send the 7-event tail twice: once inside the lane branch and once after it.
 *    We read that as an artifact of how the `return` was recovered (the
 *    duplicated blocks are byte-identical and read as an if/else whose `else`
 *    was flattened) and emit the tail once.
 *
 *    This assumption is *consistent with* the declared topic set — collapsing
 *    gives one event per declared topic — but that is **not a proof**, and it was
 *    previously written here as if it were. A class's declared topic count places
 *    no constraint on how many events one call may fire; a topic can legitimately
 *    fire twice per frame. The two "11"s are different quantities. What would
 *    actually settle it is observing the reference's own stream on a car.
 *
 * ## Purity
 * Same contract as every [SomeIpVariant]: no Android imports, so the whole wire is
 * host-JVM golden-testable. The two genuinely non-deterministic inputs — wall
 * clock and the per-route id — are **injected seams** ([nowMillis], [routeIdSource])
 * so tests pin exact bytes. Encoding primitives are reused from
 * [com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec] rather than re-implemented:
 * one protobuf encoder for the whole SOME/IP surface.
 *
 * @param pose the map-camera constants. Defaults to the reference capture; the
 *   per-model table is [LauncherMapPose.forModel]. This is the one knob a
 *   calibration would turn.
 */
class LauncherMapCnVariant(
    private val pose: LauncherMapPose = LauncherMapPose.REFERENCE_CAPTURE,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val routeIdSource: () -> Long = { Random.nextLong(MIN_ROUTE_ID, MAX_ROUTE_ID_EXCL) },
) : SomeIpVariant {

    override val name: String = "LAUNCHER_MAP_CN"

    override val serviceIds: List<Long> = TOPICS.map(::serviceIdFor).distinct()

    /**
     * The only mutable state, and it is per-ROUTE rather than per-frame: the
     * receiver correlates the route-metadata and map-camera messages by this id,
     * so it must be stable for the life of a route and change when a new one
     * starts. Generated on the first frame, cleared by [buildClearEvents].
     */
    @Volatile private var routeId: Long = 0L

    override fun buildEvents(frame: NavGuidance, counter: Int): List<Pair<Long, ByteArray>> {
        val route = routeId.takeIf { it != 0L } ?: routeIdSource().also { routeId = it }
        val now = nowMillis()
        val fix = NavFix.of(frame.lat, frame.lon)   // the ONE plausibility decision

        return listOf(
            // 1. session/protocol marker. 101 is a bare constant in the reference.
            event(TOPIC_ROUTE_SESSION) { writeVarintField(it, 4, PROTOCOL_MARKER) },

            // 2. the maneuver itself.
            event(TOPIC_MANEUVER) {
                writeVarintField(it, 1, frame.maneuverIcon.toLong())
                writeVarintField(it, 2, mainActionFor(frame.maneuverIcon).toLong())
                writeVarintField(it, 3, 0L)
                writeVarintField(it, 4, (frame.distanceMeters ?: 0).toLong())
            },

            // 3. trip progress + position. Fields 17/18 are remaining distance and
            //    remaining time: cross-checked against the UI7 strategy, which
            //    derives its ETA string from the same source field. lon BEFORE lat,
            //    the same ordering UI7 uses for its fields 19/20.
            //    No fix → the SAME stub the UI7 path uses. The reference reads one
            //    static LocationHelper singleton from all three of its strategies,
            //    and that singleton is PRE-SEEDED with the stub — no code path in it
            //    ever yields 0, so "no fix" puts the stub on the wire, not null
            //    island. (TASK-019/ISSUE-003: this used to send 0.0/0.0 on the
            //    strength of a comment claiming their helper returns 0. It does not.)
            event(TOPIC_TRIP_PROGRESS) {
                writeVarintField(it, 17, (frame.remainingDistanceMeters ?: 0).toLong())
                writeVarintField(it, 18, (frame.remainingTimeSeconds ?: 0).toLong())
                writeDoubleField(it, 11, fix?.lon ?: SomeIpRoadInfoCodec.STUB_LON)
                writeDoubleField(it, 12, fix?.lat ?: SomeIpRoadInfoCodec.STUB_LAT)
            },

            // 4. lanes (empty when the frame has none — see deviation 1).
            laneEvent(frame, now),

            // 5..9. fixed-id status beacons. The field-1 values are opaque 32-bit
            //       producer ids; they are constants in the reference and we have
            //       no derivation for them either.
            event(TOPIC_GUIDE_TICK) { writeVarintField(it, 1, ID_GUIDE_TICK) },
            event(TOPIC_ROUTING_STATUS) { writeVarintField(it, 1, ID_ROUTING_STATUS) },
            event(TOPIC_MANEUVER_STATUS_1) {
                writeVarintField(it, 1, ID_MANEUVER_STATUS_1)
                writeVarintField(it, 5, 1L)                     // 1 = navigating
                writeDoubleField(it, 12, MANEUVER_STATUS_D12)
                writeDoubleField(it, 13, MANEUVER_STATUS_D13)
            },
            event(TOPIC_MANEUVER_STATUS_2) { writeVarintField(it, 1, ID_MANEUVER_STATUS_2) },
            event(TOPIC_NAV_ACTIVE) {
                writeVarintField(it, 1, ID_NAV_ACTIVE)
                writeVarintField(it, 3, 1L)                     // 1 = active
            },

            // 10. route metadata. Timestamps on this wire are MICROseconds carried
            //     in a double (the lane message's field 9 is milliseconds — the
            //     inconsistency is the reference's, and it is on-car proven, so it
            //     is reproduced rather than tidied).
            event(TOPIC_ROUTE_METADATA) {
                writeVarintField(it, 1, route)
                writeVarintField(it, 3, 1L)
                writeDoubleField(it, 4, now * 1000.0)
            },

            // 11. the map camera — where [pose] lands.
            mapCameraEvent(route, counter, now),
        )
    }

    /**
     * "Nothing to show": the reference's stop sequence. Clears lanes, marks the
     * maneuver status and nav-active flags 0, and closes the route. Deliberately
     * does NOT send the map-camera event — a stopped route has no camera to place.
     *
     * Resets [routeId] so the next route gets a fresh correlation id.
     */
    override fun buildClearEvents(): List<Pair<Long, ByteArray>> {
        val route = routeId
        val now = nowMillis()
        routeId = 0L
        return listOf(
            emptyLaneEvent(now),
            event(TOPIC_MANEUVER_STATUS_1) {
                writeVarintField(it, 1, ID_MANEUVER_STATUS_1)
                writeVarintField(it, 5, 0L)
                writeDoubleField(it, 12, 0.0)
                writeDoubleField(it, 13, 0.0)
            },
            event(TOPIC_NAV_ACTIVE) {
                writeVarintField(it, 1, ID_NAV_ACTIVE)
                writeVarintField(it, 3, 0L)
            },
            event(TOPIC_ROUTE_METADATA) {
                writeVarintField(it, 1, route)
                writeVarintField(it, 3, 0L)
                writeDoubleField(it, 4, now * 1000.0)
            },
        )
    }

    // --- message builders -----------------------------------------------------

    private fun laneEvent(frame: NavGuidance, now: Long): Pair<Long, ByteArray> {
        val lane = frame.lane
        val codes = lane?.laneCodes.orEmpty()
        if (codes.isEmpty()) return emptyLaneEvent(now)

        val n = codes.size
        val active = BooleanArray(n) { i -> lane!!.activeIndices.getOrElse(i) { false } }
        return event(TOPIC_LANES) {
            // 1: per-lane arrow code.
            writeBytesField(it, 1, ByteArray(n) { i -> codes[i].toByte() })
            // 2: the per-lane RECOMMENDED-ARROW array, written RAW with the
            //    sentinel intact — the code when that lane is recommended, else
            //    0xFF. Do NOT apply Ui7Variant's field-29 sentinel→0 mapping
            //    here: that mapping exists only in the UI7 strategy, and the
            //    reference (which is on-car proven) writes this field straight
            //    from its active-code array without it. The two wires genuinely
            //    differ; assuming they agreed is what produced TASK-017's D5.
            writeBytesField(it, 2, ByteArray(n) { i ->
                if (active[i]) codes[i].toByte() else LANE_INACTIVE_SENTINEL
            })
            // 4/5: constant 0xFF / 0x00 runs, one byte per lane.
            writeBytesField(it, 4, ByteArray(n) { LANE_FILL_FF })
            writeBytesField(it, 5, ByteArray(n) { 0 })
            // 6: 0xFF marks INACTIVE (see deviation 2 — recomputed, not transcribed).
            writeBytesField(it, 6, ByteArray(n) { i -> if (active[i]) 0 else LANE_FILL_FF })
            // 9: milliseconds here, NOT microseconds.
            writeDoubleField(it, 9, now.toDouble())
        }
    }

    private fun emptyLaneEvent(now: Long): Pair<Long, ByteArray> = event(TOPIC_LANES) {
        writeBytesField(it, 1, EMPTY)
        writeBytesField(it, 2, EMPTY)
        writeBytesField(it, 4, EMPTY)
        writeBytesField(it, 5, EMPTY)
        writeBytesField(it, 6, EMPTY)
        writeDoubleField(it, 9, now.toDouble())
    }

    /**
     * Outer: field 1 = route/frame correlation submessage, field 3 = the map-camera
     * submessage carrying [pose], field 7 = 7 (a constant in the reference).
     */
    private fun mapCameraEvent(route: Long, counter: Int, now: Long): Pair<Long, ByteArray> {
        val correlation = message {
            writeVarintField(it, 1, route)
            writeVarintField(it, 2, counter.toLong())
            writeDoubleField(it, 3, now * 1000.0)
        }
        val camera = message {
            writeDoubleField(it, 1, pose.x)
            writeDoubleField(it, 2, pose.y)
            writeDoubleField(it, 3, pose.z)
            writeDoubleField(it, 4, pose.rollRadians)
            writeDoubleField(it, 5, pose.pitchRadians)
            writeDoubleField(it, 6, pose.yawRadians)
        }
        return event(TOPIC_MAP_CAMERA) {
            writeBytesField(it, 1, correlation)
            writeBytesField(it, 3, camera)
            writeVarintField(it, 7, MAP_CAMERA_TRAILER)
        }
    }

    // --- encoding plumbing ----------------------------------------------------

    private inline fun message(build: (ByteArrayOutputStream) -> Unit): ByteArray =
        ByteArrayOutputStream().also(build).toByteArray()

    /** Every event on this wire is its message wrapped in outer field 1, exactly
     *  as [Ui7Variant]'s RoadInfo envelope is. */
    private inline fun event(
        topic: Long,
        build: (ByteArrayOutputStream) -> Unit,
    ): Pair<Long, ByteArray> {
        val inner = message(build)
        val env = ByteArrayOutputStream()
        env.write(0x0A)                       // field 1, wire-type 2
        writeVarint(env, inner.size.toLong())
        env.write(inner)
        return topic to env.toByteArray()
    }

    companion object {
        // --- topics, in emit order ------------------------------------------
        const val TOPIC_ROUTE_SESSION: Long = 1125929972105217L
        const val TOPIC_MANEUVER: Long = 1268847189590027L
        const val TOPIC_TRIP_PROGRESS: Long = 1125929972105219L
        const val TOPIC_LANES: Long = 1268847189590028L
        const val TOPIC_GUIDE_TICK: Long = 1125951447269377L
        const val TOPIC_ROUTING_STATUS: Long = 1125951447269379L
        const val TOPIC_MANEUVER_STATUS_1: Long = 1125955742302209L
        const val TOPIC_MANEUVER_STATUS_2: Long = 1125955742302210L
        const val TOPIC_NAV_ACTIVE: Long = 1125955742302213L
        const val TOPIC_ROUTE_METADATA: Long = 1125960037335041L
        const val TOPIC_MAP_CAMERA: Long = 1125998692630531L

        /** All 11, in the order one frame emits them. */
        val TOPICS: List<Long> = listOf(
            TOPIC_ROUTE_SESSION, TOPIC_MANEUVER, TOPIC_TRIP_PROGRESS, TOPIC_LANES,
            TOPIC_GUIDE_TICK, TOPIC_ROUTING_STATUS, TOPIC_MANEUVER_STATUS_1,
            TOPIC_MANEUVER_STATUS_2, TOPIC_NAV_ACTIVE, TOPIC_ROUTE_METADATA,
            TOPIC_MAP_CAMERA,
        )

        /**
         * Topic id → service id. A topic is
         * `0x0004 | service16 | instance16 | event16`; the service id is the same
         * middle 32 bits under the tag `0x000B`, with the event id zeroed.
         *
         * The reference expresses this as `((topic ushr 16) and 0xFFFFFFFF) shl 16`
         * OR'd with `0x000B000000000000`; the 32-bit mask is load-bearing (it is
         * what strips the `0x0004` tag), not cosmetic. This spelling is the same
         * function, written so the structure is visible.
         *
         * Verified exact on all 11 topics AND on [Ui7Variant.TOPIC_ROAD], which it
         * maps to [Ui7Variant.SERVICE_ID] — an on-car-proven pair from a different
         * strategy. Pinned by `NavSomeIpLauncherMapCnTest`.
         */
        fun serviceIdFor(topic: Long): Long =
            (topic and 0x0000_FFFF_FFFF_0000L) or 0x000B_0000_0000_0000L

        // --- opaque constants (no derivation available — reference literals) ---
        private const val PROTOCOL_MARKER = 101L
        private const val ID_GUIDE_TICK = 2641158014L
        private const val ID_ROUTING_STATUS = 1729875789L
        private const val ID_MANEUVER_STATUS_1 = 3592003832L
        private const val ID_MANEUVER_STATUS_2 = 3817498742L
        private const val ID_NAV_ACTIVE = 4073768758L
        private const val MANEUVER_STATUS_D12 = 5.0
        private const val MANEUVER_STATUS_D13 = 2.2
        private const val MAP_CAMERA_TRAILER = 7L

        private const val LANE_FILL_FF: Byte = -1     // 0xFF

        /**
         * The reference's "this lane is NOT the recommended one" sentinel, as it
         * appears in lane field 2. Same byte as [LANE_FILL_FF], different meaning
         * — that one is a constant run, this one is a value in a data array — so
         * it is named separately and must not be folded into it.
         */
        private const val LANE_INACTIVE_SENTINEL: Byte = -1   // 0xFF

        private val EMPTY = ByteArray(0)

        internal const val MIN_ROUTE_ID = 1_000_000_000L
        internal const val MAX_ROUTE_ID_EXCL = 10_000_000_000L

        /**
         * Maneuver code → this wire's "main action" enum (field 2 of the maneuver
         * message). A distinct, coarser mapping from the one [Ui7Variant] uses for
         * its field 28 — same input, different receiver vocabulary.
         */
        fun mainActionFor(maneuverCode: Int): Int = when (maneuverCode) {
            1 -> 2
            2 -> 3
            3, 4 -> 4
            5, 6 -> 5
            7 -> 6
            8 -> 7
            9 -> 8
            10 -> 9
            11, 12 -> 1
            else -> 0
        }
    }
}
