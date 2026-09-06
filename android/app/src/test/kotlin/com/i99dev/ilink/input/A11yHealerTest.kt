package com.i99dev.ilink.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure-logic tests for [A11yHealer.planToggle] — the remove-then-re-add CSV
 * computation that forces the framework to rebind a crashed a11y service.
 */
class A11yHealerTest {
    private val remote = "com.i99dev.ilink/com.i99dev.ilink.input.RemoteControlAccessibilityService"
    private val watchdog = "com.i99dev.ilink/com.i99dev.ilink.input.WatchdogAccessibilityService"
    private val talkback = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
    private val bydVoice = "com.byd.autovoice/com.byd.autovoice_bydapi.visiblespeech.engine.collect.abs.SceneSayService"

    @Test
    fun noCrash_returnsNull() {
        assertNull(A11yHealer.planToggle(listOf(remote, watchdog, talkback), emptyList()))
    }

    @Test
    fun crashedRemote_togglesBothOurs_preservesForeignServices() {
        val listed = listOf(talkback, remote, watchdog, bydVoice)
        val plan = A11yHealer.planToggle(listed, listOf(remote))!!
        // "without" drops both of ours, keeps foreign services in order.
        assertEquals("$talkback:$bydVoice", plan.first)
        // "with" re-appends our enabled services after the preserved ones.
        assertEquals("$talkback:$bydVoice:$remote:$watchdog", plan.second)
    }

    @Test
    fun onlyEnabledOursAreReAdded() {
        // Watchdog was never enabled (not listed) — heal must not invent it.
        val listed = listOf(remote, talkback)
        val plan = A11yHealer.planToggle(listed, listOf(remote))!!
        assertEquals(talkback, plan.first)
        assertEquals("$talkback:$remote", plan.second)
    }

    @Test
    fun toggleActuallyChangesValue() {
        // The intermediate (without) value must differ from the final (with) so
        // the framework's ContentObserver sees a real transition and rebinds.
        val listed = listOf(remote, watchdog)
        val plan = A11yHealer.planToggle(listed, listOf(remote, watchdog))!!
        assert(plan.first != plan.second)
        assertEquals("", plan.first)
        assertEquals("$remote:$watchdog", plan.second)
    }

    // ---- planEnable (auto-enable on app open) ----

    @Test
    fun planEnable_appendsBothWhenMissing_preservingForeign() {
        assertEquals("$talkback:$remote:$watchdog", A11yHealer.planEnable(listOf(talkback)))
    }

    @Test
    fun planEnable_appendsOnlyTheMissingOne() {
        assertEquals("$remote:$talkback:$watchdog", A11yHealer.planEnable(listOf(remote, talkback)))
    }

    @Test
    fun planEnable_nullWhenBothAlreadyEnabled() {
        assertNull(A11yHealer.planEnable(listOf(remote, watchdog, talkback)))
    }
}
