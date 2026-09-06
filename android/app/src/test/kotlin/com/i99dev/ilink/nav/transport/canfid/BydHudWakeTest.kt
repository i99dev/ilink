package com.i99dev.ilink.nav.transport.canfid

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

/**
 * Host tests for the 7.0UI HUD wake handshake ([BydHudWake] + [BydGuidance]).
 * The wake writes the instrument NAVI_STATUS = NAVI_ACTIVE (2) and the setting
 * NAVI_SCREEN_STATUS = NAVI_SCREEN_ON (3); the SHELL form is
 * `service call autoservice 6 i32 <op> i32 <fid> i32 <value>` (op = device).
 * Confirms verify/cache/backoff/re-arm, and guards the value (must be the active
 * STATE 2, not a command code).
 */
class BydHudWakeTest {

    /** Records writes; models a cluster that "wakes" (reads NAVI_STATUS back ==
     *  NAVI_ACTIVE) once it receives that write on the chosen path. */
    private class FakeFidWriter(
        private val shellSupported: Boolean = true,
        /** if false the cluster never wakes (models the retry/backoff path). */
        private val wakes: Boolean = true,
    ) : FidWriter {
        val typedInts = mutableListOf<Pair<Int, Int>>()
        val settingInts = mutableListOf<Pair<Int, Int>>()
        val shellWrites = mutableListOf<Triple<Int, Int, Int>>() // fid, value, op
        var naviStatus = 0

        override fun instrumentInt(fid: Int, value: Int) {
            typedInts += fid to value
            maybeWake(fid, value)
        }

        override fun settingInt(fid: Int, value: Int) { settingInts += fid to value }

        override fun instrumentIntShell(fid: Int, value: Int, op: Int): Boolean {
            if (!shellSupported) return false
            shellWrites += Triple(fid, value, op)
            maybeWake(fid, value)
            return true
        }

        override fun instrumentBytes(fid: Int, value: ByteArray) {}
        override fun instrumentRead(fid: Int): Int = if (fid == BydFid.NAVI_STATUS) naviStatus else 0
        override fun cameraGuidance(type: Int, distanceMeters: Int, state: Int) {}
        override fun safeGuidance(type: Int, distanceMeters: Int, state: Int) {}

        private fun maybeWake(fid: Int, value: Int) {
            if (wakes && fid == BydFid.NAVI_STATUS && value == BydFid.NAVI_ACTIVE) {
                naviStatus = BydFid.NAVI_ACTIVE
            }
        }
    }

    @Test
    fun shell_path_wakes_with_correct_values_then_caches() {
        val w = FakeFidWriter(shellSupported = true)
        var t = 10_000L
        val wake = BydHudWake { t }

        assertTrue(wake.ensure(w), "SHELL wake should verify")
        assertTrue(wake.isAwake)
        // SHELL form: instrument NAVI_STATUS=2 (op INSTRUMENT), setting NAVI_SCREEN_STATUS=3 (op SETTING).
        assertTrue(Triple(BydFid.NAVI_STATUS, BydFid.NAVI_ACTIVE, BydFid.SHELL_OP_INSTRUMENT) in w.shellWrites)
        assertTrue(Triple(BydFid.NAVI_SCREEN_STATUS, BydFid.NAVI_SCREEN_ON, BydFid.SHELL_OP_SETTING) in w.shellWrites)

        // Cached: a later ensure() writes nothing more (awake short-circuits).
        val before = w.shellWrites.size + w.typedInts.size
        t += 5_000
        assertTrue(wake.ensure(w))
        assertEquals(before, w.shellWrites.size + w.typedInts.size)
    }

    @Test
    fun falls_back_to_typed_when_shell_unsupported() {
        val w = FakeFidWriter(shellSupported = false)
        var t = 10_000L
        val wake = BydHudWake { t }

        assertTrue(wake.ensure(w), "TYPED fallback should verify")
        assertTrue(BydFid.NAVI_STATUS to BydFid.NAVI_ACTIVE in w.typedInts)
        assertTrue(BydFid.NAVI_SCREEN_STATUS to BydFid.NAVI_SCREEN_ON in w.settingInts)
    }

    @Test
    fun writes_the_active_state_value_not_a_command_code() {
        val w = FakeFidWriter(shellSupported = false)
        var t = 10_000L
        BydHudWake { t }.ensure(w)
        // NAVI_STATUS must be written with the active STATE (2), never a stray code.
        assertEquals(BydFid.NAVI_ACTIVE, w.typedInts.first { it.first == BydFid.NAVI_STATUS }.second)
    }

    @Test
    fun backoff_rate_limits_attempts_when_never_awake() {
        val w = FakeFidWriter(shellSupported = true, wakes = false)
        var t = 10_000L
        val wake = BydHudWake { t }

        assertFalse(wake.ensure(w)) // attempt 1 (shell → typed)
        val afterFirst = w.shellWrites.size + w.typedInts.size
        assertFalse(wake.ensure(w)) // same instant → rate-limited, no new writes
        assertEquals(afterFirst, w.shellWrites.size + w.typedInts.size, "rate-limited within RETRY_MS")

        t += 1_100 // past RETRY_MS
        assertFalse(wake.ensure(w)) // attempt 2 (typed)
        assertTrue(w.shellWrites.size + w.typedInts.size > afterFirst)
        assertFalse(wake.isAwake)
    }

    @Test
    fun reset_re_arms_the_handshake() {
        val w = FakeFidWriter(shellSupported = true)
        var t = 10_000L
        val wake = BydHudWake { t }
        assertTrue(wake.ensure(w))

        wake.reset()
        assertFalse(wake.isAwake)
        w.naviStatus = 0 // cluster went back to sleep (ignition/park)
        t += 5_000
        val before = w.shellWrites.size
        assertTrue(wake.ensure(w), "re-arm should run the handshake again")
        assertTrue(w.shellWrites.size > before)
    }
}
