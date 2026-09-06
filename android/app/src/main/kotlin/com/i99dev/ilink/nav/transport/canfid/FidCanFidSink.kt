package com.i99dev.ilink.nav.transport.canfid

import com.i99dev.ilink.nav.transport.CanFidGuidanceSink

/**
 * Bridges the transport's [CanFidGuidanceSink] to the pure [BydGuidance] FID
 * sequences over an injected [FidWriter]. The [writer] is supplied by the
 * daemon once its HAL guidance verb lands; until then it's null and the sink
 * reports the HAL absent (so the controller stays on SOME/IP).
 */
class FidCanFidSink(private val writer: FidWriter?) : CanFidGuidanceSink {

    override fun isHalPresent(): Boolean = writer?.ready() == true

    override fun turnOnNavi() {
        writer?.let { BydGuidance.turnOnNavi(it) }
    }

    override fun turnOffNavi() {
        writer?.let { BydGuidance.turnOffNavi(it) }
    }

    override fun ensureNaviActive() {
        val w = writer ?: return
        if (BydGuidance.getNaviStatus(w) != BydFid.NAVI_ACTIVE) BydGuidance.turnOnNavi(w)
    }

    override fun sendSimpleGuidanceInfo(iconCode: Int, distanceMeters: Int) {
        writer?.let { BydGuidance.sendSimpleGuidanceInfo(it, iconCode, distanceMeters) }
    }

    override fun sendNextPathName(road: String) {
        writer?.let { BydGuidance.sendNextPathName(it, road) }
    }

    override fun sendLaneGuidanceInfo(laneCodes: IntArray, distanceMeters: Int) {
        writer?.let { BydGuidance.sendLaneGuidanceInfo(it, laneCodes, distanceMeters) }
    }

    override fun sendCameraGuidance(type: Int, distanceMeters: Int, state: Int) {
        writer?.let { BydGuidance.sendCameraGuidanceInfo(it, type, distanceMeters, state) }
    }

    override fun sendSafeGuidance(type: Int, distanceMeters: Int, state: Int) {
        writer?.let { BydGuidance.sendSafeGuidanceInfo(it, type, distanceMeters, state) }
    }
}
