package com.i99dev.ilink.nav.transport.canfid

import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge

/**
 * The privileged [FidWriter] — routes the CAN-FID guidance writes through the
 * EXISTING DashDaemon JSON-RPC (shell uid), so it adds NO new daemon code and
 * can't destabilise the car-control path.
 *
 * SAFE-BY-DEFAULT: [isHalPresent]/[ready] gate on `verified`, which stays false
 * until M0 confirms on-car (a) the instrument/setting device-type for these FIDs
 * and (b) that the camera/safety SDK verb exists in the daemon. Until then the
 * controller never selects CAN-FID (SOME/IP is preferred anyway) and nothing here
 * fires — no risk of writing wrong FIDs. M0 flips [verified] and fills the two
 * UNVERIFIED constants below.
 */
class DaemonFidWriter : FidWriter {

    private val client get() = AdbShellBridge.daemonClient()

    /** True only after M0 calibration; keeps CAN-FID inert until then. */
    @Volatile var verified: Boolean = false

    /** Daemon reachable AND calibrated — gates CAN-FID selection. */
    override fun ready(): Boolean = verified && runCatching { client.ping() }.getOrDefault(false)

    override fun instrumentInt(fid: Int, value: Int) {
        if (!verified) return
        runCatching { client.setInt(INSTRUMENT_DT, fid, value) }
            .onFailure { Log.w(TAG, "instrumentInt($fid)=$value: ${it.message}") }
    }

    override fun instrumentBytes(fid: Int, value: ByteArray) {
        if (!verified) return
        val b64 = android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP)
        runCatching {
            client.send("setB", body = {
                put("dt", INSTRUMENT_DT); put("key", fid); put("bytes", b64)
            })
        }.onFailure { Log.w(TAG, "instrumentBytes($fid): ${it.message}") }
    }

    override fun settingInt(fid: Int, value: Int) {
        if (!verified) return
        runCatching { client.setInt(SETTING_DT, fid, value) }
            .onFailure { Log.w(TAG, "settingInt($fid)=$value: ${it.message}") }
    }

    override fun instrumentRead(fid: Int): Int {
        if (!verified) return 0
        return runCatching { client.getInt(INSTRUMENT_DT, fid).optInt("value", 0) }.getOrDefault(0)
    }

    // Camera/safety are vendor-SDK methods (BYDAutoInstrumentDevice.send*GuidanceInfo),
    // NOT FID writes — they need a daemon verb the stock daemon lacks. Until that
    // verb is added on-car, these are graceful no-ops (the daemon rejects the op).
    override fun cameraGuidance(type: Int, distanceMeters: Int, state: Int) =
        sdkGuidance("camera", type, distanceMeters, state)

    override fun safeGuidance(type: Int, distanceMeters: Int, state: Int) =
        sdkGuidance("safe", type, distanceMeters, state)

    private fun sdkGuidance(kind: String, type: Int, dist: Int, state: Int) {
        if (!verified) return
        runCatching {
            client.send("instGuidance", body = {
                put("kind", kind); put("type", type); put("dist", dist); put("state", state)
            })
        }.onFailure { Log.w(TAG, "$kind guidance: ${it.message}") }
    }

    companion object {
        private const val TAG = "DaemonFidWriter"

        // UNVERIFIED (M0): the BYDAutoManager device-type for the instrument /
        // setting FIDs. Placeholders — never used while verified == false.
        private const val INSTRUMENT_DT = 0
        private const val SETTING_DT = 0
    }
}
