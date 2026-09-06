package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.logic.SomeIpRoadInfoCodec
import com.i99dev.ilink.nav.transport.HudRenderer
import com.i99dev.ilink.nav.transport.NoopHudRenderer

/**
 * The SOME/IP variant we ship today, extracted from
 * [SomeIpHudTransport][com.i99dev.ilink.nav.transport.SomeIpHudTransport] **verbatim**.
 * One service, one topic, one RoadInfo event per frame — byte-identical to the
 * reference 2.4.2.1's UI7 strategy for any frame WITHOUT a position. Frames that
 * carry a real fix additionally populate the position fields the reference left
 * hardcoded to Beijing (TASK-005); the shape/ordering of the wire is unchanged.
 *
 * [SERVICE_ID] / [TOPIC_ROAD] are **on-car-proven** constants (B5 / L8 5.0UI
 * clusters subscribe to TOPIC_ROAD; Huawei-HMI Di5.1 trims read SOME/IP RoadInfo
 * even though they ignore the instrument HAL). Changing either silently kills the
 * HUD with no error anywhere — `NavSomeIpVariantTest` pins both to literals.
 *
 * Payload construction is delegated to [SomeIpRoadInfoCodec], not reimplemented:
 * one encoder, one wire.
 *
 * As of TASK-002 this is the ONLY definition of these bytes: the transport no
 * longer builds a payload inline, it fires whatever this returns. So the frozen
 * goldens in `NavSomeIpVariantTest` pin the real wire, not a copy of it.
 */
class Ui7Variant(
    private val renderer: HudRenderer = NoopHudRenderer,
) : SomeIpVariant {

    override val name: String = "UI7"

    override val serviceIds: List<Long> = listOf(SERVICE_ID)

    /**
     * Exactly the arguments `SomeIpHudTransport.push` passes today, in the same
     * order — including `distanceMeters ?: 0`, which is what a non-drawable frame
     * (null distance) collapses to. The drawable gate itself lives upstream in the
     * controller, so this stays a pure marshaller.
     */
    override fun buildEvents(frame: NavGuidance, counter: Int): List<Pair<Long, ByteArray>> {
        val payload = SomeIpRoadInfoCodec.buildRoadInfo(
            counter = counter,
            maneuverCode = frame.maneuverIcon,
            distanceMeters = frame.distanceMeters ?: 0,
            roadName = frame.roadName,
            eta = renderer.formatEta(frame.remainingTimeSeconds),
            iconPng = renderer.iconPng(frame.maneuverIcon),
            guideLine = renderer.guideLine(frame.maneuverIcon, frame.lat, frame.lon, frame.heading),
            lane = frame.lane,
            // TASK-005: fields 19/20/31. Straight pass-through of the position the
            // ingest boundary stamped — null (no fix / no permission) reproduces
            // the previous Beijing-stub wire byte-for-byte.
            lat = frame.lat,
            lon = frame.lon,
        )
        return listOf(TOPIC_ROAD to payload)
    }

    /** The blank RoadInfo a clear() sends — same wire, no maneuver, no icon. */
    override fun buildClearEvents(): List<Pair<Long, ByteArray>> {
        val blank = SomeIpRoadInfoCodec.buildRoadInfo(
            counter = 0, maneuverCode = 0, distanceMeters = 0, roadName = "",
            eta = "", iconPng = ByteArray(0), guideLine = "[]", lane = null,
        )
        return listOf(TOPIC_ROAD to blank)
    }

    companion object {
        /** HUD service id (0x010A). Started/stopped via `transact(4)`/`transact(5)`. */
        const val SERVICE_ID: Long = 3097367205183488L

        /** RoadInfo event topic the 5.0UI cluster subscribes to. */
        const val TOPIC_ROAD: Long = 1127042368241665L
    }
}
