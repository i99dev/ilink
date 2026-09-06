package com.i99dev.ilink.nav

import android.view.accessibility.AccessibilityNodeInfo
import com.i99dev.ilink.nav.ingest.NavA11yDispatcher
import com.i99dev.ilink.nav.ingest.NavA11yHandler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host coverage for dispatcher REGISTRATION only — the `activePackages` set that is the
 * a11y service's cheap event gate.
 *
 * NOT covered here: `onWindow` dispatch. It takes a real [AccessibilityNodeInfo] and reads
 * `packageName` off it; there is no host-JVM implementation of that class. The *decision*
 * `onWindow` makes (root ownership) is tested as a pure predicate in
 * [NavA11yReadPolicyTest]; the wiring of that predicate into `onWindow` is pending on-car
 * verification.
 */
class NavA11yDispatcherTest {

    private class FakeSource(override val packages: Set<String>) : NavA11yHandler {
        var calls = 0
        override fun onWindow(root: AccessibilityNodeInfo, pkg: String) {
            calls++
        }
    }

    private val registered = mutableListOf<NavA11yHandler>()

    private fun register(h: NavA11yHandler) {
        NavA11yDispatcher.register(h)
        registered += h
    }

    @After
    fun tearDown() {
        registered.forEach { NavA11yDispatcher.unregister(it) }
        registered.clear()
    }

    @Test
    fun activePackagesIsEmptyWithNothingRegistered() {
        assertTrue(NavA11yDispatcher.activePackages.isEmpty())
    }

    @Test
    fun activePackagesIsTheUnionOfEverySource() {
        register(FakeSource(setOf("com.google.android.apps.maps")))
        register(FakeSource(setOf("com.waze", "ru.yandex.yandexmaps")))
        assertEquals(
            setOf("com.google.android.apps.maps", "com.waze", "ru.yandex.yandexmaps"),
            NavA11yDispatcher.activePackages,
        )
    }

    @Test
    fun unregisterRemovesThatSourcesPackages() {
        val maps = FakeSource(setOf("com.google.android.apps.maps"))
        val waze = FakeSource(setOf("com.waze"))
        register(maps)
        register(waze)
        NavA11yDispatcher.unregister(waze)
        registered.remove(waze)
        assertEquals(setOf("com.google.android.apps.maps"), NavA11yDispatcher.activePackages)
    }

    @Test
    fun registerIsIdempotentByIdentity() {
        val maps = FakeSource(setOf("com.google.android.apps.maps"))
        register(maps)
        NavA11yDispatcher.register(maps)
        // Same instance twice must not double-register, or one window read would be
        // dispatched to it twice and double-count against its self-throttle.
        NavA11yDispatcher.unregister(maps)
        registered.remove(maps)
        assertTrue(NavA11yDispatcher.activePackages.isEmpty())
    }

    @Test
    fun onWindowIsANoOpForNullInputs() {
        register(FakeSource(setOf("com.waze")))
        // Null-guard only — a non-null root cannot be constructed on a host JVM.
        assertFalse(NavA11yDispatcher.onWindow(null, null))
        assertFalse(NavA11yDispatcher.onWindow("com.waze", null))
    }
}
