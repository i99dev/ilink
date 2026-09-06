package com.i99dev.ilink.nav.transport.canfid

/**
 * The BYD instrument-cluster FID constants + guidance write-sequences,
 * **verbatim** from the reference's `CarControlImpl` (decompiled). PURE: the exact
 * order + values of the CAN/HAL writes live here and are host-testable; the
 * privileged HAL reflection (`BYDAutoInstrumentDevice` / `BYDAutoSettingDevice`)
 * is injected via [FidWriter], implemented by the daemon (shell uid, has the
 * `android.hardware.bydauto.*` classpath).
 */
object BydFid {
    // INSTRUMENT device (ev.intValue / ev.bufferDataValue → dev.set(int[],ev))
    const val NAVI_STATUS = 1138753594 // read=getNaviStatus, write=on/off
    const val GUIDE_ICON = 1139806224
    const val GUIDE_DUAL_ICON = 1139806256
    const val GUIDE_DIST = 1139806232
    const val SECONDARY_ICON = 1139834896
    const val SECONDARY_DIST = 1139834904
    const val NEXT_PATHNAME_BYTES = 1140461576 // bufferDataValue = UTF-16LE (BYD instrument HAL)
    const val TRIP_HOUR = 1139810320
    const val TRIP_MINUTE = 1139810328
    const val TRIP_MILEAGE = 1139810344
    const val TRIP_SECOND = 1139810334 // always 0

    // SETTING device (reflected getInstance/set)
    const val NAVI_SCREEN_STATUS = 1276174357 // = 3 when navi active
    const val LANE_NUM = 1285554200
    const val LANE_DIST = 1285554184
    val LANE_STATES = intArrayOf(
        1285554208, 1285554212, 1285554216, 1285554220, 1285554224, 1285554228,
        1285554232, 1285554236, 1285554260, 1285554264, 1285554268, 1285554272,
    )

    const val LANE_EMPTY = 255
    const val NAVI_ACTIVE = 2
    const val NAVI_STOPPED = 4

    // --- 7.0UI (Leopard 7 / Ti7) HUD "wake" handshake -----------------------
    // The 7.0UI cluster ignores guidance writes until the HUD is "woken": set the
    // instrument NAVI_STATUS = NAVI_ACTIVE (2) AND the setting NAVI_SCREEN_STATUS
    // = NAVI_SCREEN_ON (3); awake is confirmed by reading NAVI_STATUS back == 2.
    // Both writes already exist in the typed path (this is the reference's nav-on
    // sequence); the wake adds a verify + a raw `service call` SHELL fallback for
    // firmwares where the reflected HAL is null.
    const val NAVI_SCREEN_ON = 3 // NAVI_SCREEN_STATUS value (the second enable register)

    // `service call autoservice` op = the FIRST i32 arg: 0x3EF selects the
    // instrument device, 0x3FF the setting device. The VALUE is the LAST arg —
    // form: `service call autoservice 6 i32 <op> i32 <fid> i32 <value>`.
    const val SHELL_OP_INSTRUMENT = 0x3ef
    const val SHELL_OP_SETTING = 0x3ff
}

/**
 * The privileged write primitive — implemented by the daemon over the BYD HAL.
 * Separating it from [BydGuidance] keeps the FID sequencing testable without a
 * car and isolates the M0-gated reflection.
 */
interface FidWriter {
    /** Is the HAL reachable + calibrated? Gates CAN-FID selection (default true;
     *  the daemon writer returns false until M0 verifies). */
    fun ready(): Boolean = true

    fun instrumentInt(fid: Int, value: Int)
    fun instrumentBytes(fid: Int, value: ByteArray)
    fun settingInt(fid: Int, value: Int)
    fun instrumentRead(fid: Int): Int

    /**
     * The raw-binder SHELL form of a feature write —
     * `service call autoservice 6 i32 <op> i32 <fid> i32 <value>` — which drives
     * the cluster even on firmwares where the reflected `BYDAutoInstrumentDevice`
     * is null (shell is the only working path on those firmwares). [op] is the
     * device selector (first i32): instrument vs setting. Requires the shell uid
     * (the daemon has it). Returns true iff the command executed. Default:
     * unsupported (host tests / non-privileged writers).
     */
    fun instrumentIntShell(fid: Int, value: Int, op: Int): Boolean = false

    // Camera / safety go through the BYD vendor SDK methods (NOT raw FIDs):
    // BYDAutoInstrumentDevice.sendCameraGuidanceInfo / sendSafeGuidanceInfo.
    fun cameraGuidance(type: Int, distanceMeters: Int, state: Int)
    fun safeGuidance(type: Int, distanceMeters: Int, state: Int)
}

/** The guidance write-sequences (exact order/values from `CarControlImpl`). */
object BydGuidance {

    /** FIDs icon + dualIcon (same value) + dist. */
    fun sendSimpleGuidanceInfo(w: FidWriter, icon: Int, dist: Int) {
        w.instrumentInt(BydFid.GUIDE_ICON, icon)
        w.instrumentInt(BydFid.GUIDE_DUAL_ICON, icon)
        w.instrumentInt(BydFid.GUIDE_DIST, dist)
    }

    fun sendNextPathName(w: FidWriter, road: String) {
        // The BYD instrument HAL reads NEXT_PATHNAME_BYTES as UTF-16LE (verified vs
        // the reference's xh.b = UTF-16LE). Sending UTF-8 made the cluster read our ASCII
        // bytes as wide chars — "Al" (0x41,0x6C) → 0x6C41 = '汁' — i.e. garbled Chinese.
        w.instrumentBytes(BydFid.NEXT_PATHNAME_BYTES, road.toByteArray(Charsets.UTF_16LE))
    }

    fun sendSecondaryGuidanceInfo(w: FidWriter, icon: Int, dist: Int) {
        w.instrumentInt(BydFid.SECONDARY_ICON, icon)
        w.instrumentInt(BydFid.SECONDARY_DIST, dist)
    }

    /** ETA on the cluster: remaining time split into whole hours + minutes (from
     *  seconds) and remaining distance (metres), each clamped to the cluster's
     *  field range — hour 0..254, minute 0..59, mileage 0..9_999_000m. Call only
     *  when both remaining time and distance are present. */
    fun sendTripInfo(w: FidWriter, remainingTimeSeconds: Int, remainingDistanceMeters: Int) {
        val totalMinutes = remainingTimeSeconds / 60
        w.instrumentInt(BydFid.TRIP_HOUR, (totalMinutes / 60).coerceIn(0, 254))
        w.instrumentInt(BydFid.TRIP_MINUTE, (totalMinutes % 60).coerceIn(0, 59))
        w.instrumentInt(BydFid.TRIP_MILEAGE, remainingDistanceMeters.coerceIn(0, 9_999_000))
    }

    /** SETTING device: lane count, then 12 lane slots (empty = 255), then lane dist. */
    fun sendLaneGuidanceInfo(w: FidWriter, codes: IntArray, dist: Int) {
        w.settingInt(BydFid.LANE_NUM, codes.size)
        for (i in 0 until 12) {
            w.settingInt(BydFid.LANE_STATES[i], if (i < codes.size) codes[i] else BydFid.LANE_EMPTY)
        }
        w.settingInt(BydFid.LANE_DIST, dist)
    }

    /** Wake the HUD via the typed HAL: instrument NAVI_STATUS = NAVI_ACTIVE and
     *  setting NAVI_SCREEN_STATUS = NAVI_SCREEN_ON. (See [wakeShell] for the raw
     *  fallback and [BydHudWake] for the verify/retry state machine.) */
    fun wakeTyped(w: FidWriter) {
        w.instrumentInt(BydFid.NAVI_STATUS, BydFid.NAVI_ACTIVE)
        w.settingInt(BydFid.NAVI_SCREEN_STATUS, BydFid.NAVI_SCREEN_ON)
    }

    /** Wake the HUD via the raw `service call` SHELL form (no HAL classpath
     *  needed): instrument NAVI_STATUS and setting NAVI_SCREEN_STATUS, each with
     *  its device op. Returns true iff both writes executed. */
    fun wakeShell(w: FidWriter): Boolean {
        val navi = w.instrumentIntShell(BydFid.NAVI_STATUS, BydFid.NAVI_ACTIVE, BydFid.SHELL_OP_INSTRUMENT)
        val screen = w.instrumentIntShell(BydFid.NAVI_SCREEN_STATUS, BydFid.NAVI_SCREEN_ON, BydFid.SHELL_OP_SETTING)
        return navi && screen
    }

    /** The 7.0UI cluster reports NAVI_STATUS == [BydFid.NAVI_ACTIVE] once the HUD
     *  is awake — the confirmation the wake handshake checks. */
    fun isHudAwake(w: FidWriter): Boolean =
        runCatching { w.instrumentRead(BydFid.NAVI_STATUS) == BydFid.NAVI_ACTIVE }.getOrDefault(false)

    /** The HUD-on entry: the verified, cached wake handshake (via [BydHudWake]). */
    fun turnOnNavi(w: FidWriter) = wakeTyped(w)

    fun turnOffNavi(w: FidWriter) = sendAutoNaviStatus(w, BydFid.NAVI_STOPPED)

    fun getNaviStatus(w: FidWriter): Int = w.instrumentRead(BydFid.NAVI_STATUS)

    /** Speed-camera glyph (BYD vendor SDK). Clear = [clearCamera]. */
    fun sendCameraGuidanceInfo(w: FidWriter, type: Int, distanceMeters: Int, state: Int) =
        w.cameraGuidance(type, distanceMeters, state)

    fun clearCamera(w: FidWriter) = w.cameraGuidance(0, -1, 1)

    /** Safety/enforcement glyph (police/hazard) via the BYD vendor SDK. */
    fun sendSafeGuidanceInfo(w: FidWriter, type: Int, distanceMeters: Int, state: Int) =
        w.safeGuidance(type, distanceMeters, state)

    fun clearSafe(w: FidWriter) = w.safeGuidance(0, -1, 1)

    /** status=2 sets the nav-screen layout; status=4 clears every guidance register. */
    fun sendAutoNaviStatus(w: FidWriter, status: Int) {
        w.instrumentInt(BydFid.NAVI_STATUS, status)
        if (status == BydFid.NAVI_ACTIVE) {
            w.settingInt(BydFid.NAVI_SCREEN_STATUS, 3)
        }
        if (status == BydFid.NAVI_STOPPED) {
            w.instrumentInt(BydFid.GUIDE_ICON, 0)
            w.instrumentInt(BydFid.GUIDE_DUAL_ICON, 0)
            w.instrumentInt(BydFid.GUIDE_DIST, -1)
            w.instrumentBytes(BydFid.NEXT_PATHNAME_BYTES, ByteArray(0))
            w.instrumentInt(BydFid.TRIP_MILEAGE, -1)
            w.instrumentInt(BydFid.TRIP_HOUR, 0)
            w.instrumentInt(BydFid.TRIP_MINUTE, 0)
            w.instrumentInt(BydFid.TRIP_SECOND, 0)
        }
    }
}
