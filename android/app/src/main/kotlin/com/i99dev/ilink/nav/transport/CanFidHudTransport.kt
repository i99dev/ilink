package com.i99dev.ilink.nav.transport

import com.i99dev.ilink.nav.domain.NavGuidance

/**
 * FALLBACK cluster transport — BYD instrument HAL via the privileged daemon
 * (the path the reference actually ships). Writes `BYDAutoInstrumentDevice` FIDs +
 * `sendSimpleGuidanceInfo` / lane / navi-status as shell uid.
 *
 * Per the plan's review: this is **build-new in the daemon**, NOT an extension
 * of `AutoManagerActuator` (which has no HAL surface). The privileged writes
 * live behind [CanFidGuidanceSink], implemented by the daemon once the FID
 * table (extraction) + the daemon RPC verb are in. Until then [isAvailable]
 * returns false and the controller prefers SOME/IP — graceful, not broken.
 */
class CanFidHudTransport(
    private val sink: CanFidGuidanceSink?,
    private val renderer: HudRenderer = NoopHudRenderer,
) : HudTransport {

    override val name: String = "CAN_FID"

    override fun isAvailable(): Boolean = sink?.isHalPresent() == true

    override fun start() {
        sink?.turnOnNavi()
    }

    override fun stop() {
        sink?.turnOffNavi()
    }

    override fun push(frame: NavGuidance, counter: Int) {
        val s = sink ?: error("CAN-FID sink not wired")
        s.ensureNaviActive()
        s.sendSimpleGuidanceInfo(renderer.iconCode(frame.maneuverIcon), frame.distanceMeters ?: -1)
        if (frame.roadName.isNotEmpty()) s.sendNextPathName(frame.roadName)
        frame.lane?.let { l -> s.sendLaneGuidanceInfo(l.laneCodes.toIntArray(), l.distanceToSplitMeters) }
        // camera / safety glyphs (Waze alerts) — only when populated
        frame.cameraType?.let { s.sendCameraGuidance(it, frame.cameraDistance ?: -1, frame.cameraState ?: 0) }
        frame.safetyType?.let { s.sendSafeGuidance(it, frame.safetyDistance ?: -1, frame.safetyState ?: 0) }
    }

    override fun clear() {
        sink?.turnOffNavi()
    }
}

/**
 * Privileged guidance writer over the BYD instrument HAL — implemented by the
 * daemon (runs as shell uid, has `android.hardware.bydauto.*` on its classpath).
 * Signatures mirror the reference's `ICarControl` guidance methods; the exact FID
 * integers + `BYDAutoEventValue` marshalling are filled from the extracted
 * CAN-FID table.
 */
interface CanFidGuidanceSink {
    /** Is `BYDAutoInstrumentDevice` on the daemon classpath + writable (uid 2000)? */
    fun isHalPresent(): Boolean

    /** `sendAutoNaviStatus(2)` — activate the factory nav HUD. */
    fun turnOnNavi()

    /** `sendAutoNaviStatus(4)` — clears icon/dist/road/trip sentinels. */
    fun turnOffNavi()

    /** Re-issue [turnOnNavi] if `getNaviStatus() != ACTIVE`. */
    fun ensureNaviActive()

    /** FIDs icon/dualIcon/dist + HAL `sendSimpleGuidanceInfo`. dist < 0 = none. */
    fun sendSimpleGuidanceInfo(iconCode: Int, distanceMeters: Int)

    /** FID road-name bytes + HAL `sendNextPathName`. */
    fun sendNextPathName(road: String)

    /** Setting-device lane FIDs (count/dist + 12 lane slots, empty = 255). */
    fun sendLaneGuidanceInfo(laneCodes: IntArray, distanceMeters: Int)

    /** Speed-camera glyph via the BYD vendor SDK (`sendCameraGuidanceInfo`). */
    fun sendCameraGuidance(type: Int, distanceMeters: Int, state: Int)

    /** Safety/enforcement glyph (police/hazard) via `sendSafeGuidanceInfo`. */
    fun sendSafeGuidance(type: Int, distanceMeters: Int, state: Int)
}
