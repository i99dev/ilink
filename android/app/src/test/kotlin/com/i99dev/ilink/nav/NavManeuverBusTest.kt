package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.ingest.NavManeuverBus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Host coverage for the per-package maneuver bus. Staleness (the elapsedRealtime
 *  window) is exercised on-car; the host clock is constant. */
class NavManeuverBusTest {

    @Test
    fun setAndLatestPerPackage() {
        NavManeuverBus.clear("com.google.android.apps.maps")
        NavManeuverBus.clear("com.waze")
        NavManeuverBus.clear("ru.yandex.yandexmaps")
        assertNull(NavManeuverBus.latest("com.google.android.apps.maps"))

        NavManeuverBus.set("com.google.android.apps.maps", 7)
        NavManeuverBus.set("com.waze", 2)
        assertEquals(7, NavManeuverBus.latest("com.google.android.apps.maps"))
        assertEquals(2, NavManeuverBus.latest("com.waze"))
        // packages are isolated
        assertNull(NavManeuverBus.latest("ru.yandex.yandexmaps"))
    }

    @Test
    fun setRejectsOutOfRangeCodes() {
        NavManeuverBus.clear("com.waze")
        NavManeuverBus.set("com.waze", 2)
        NavManeuverBus.set("com.waze", 0) // ignored
        NavManeuverBus.set("com.waze", 99) // ignored
        assertEquals(2, NavManeuverBus.latest("com.waze")) // unchanged
    }

    @Test
    fun clearDropsManeuver() {
        NavManeuverBus.set("com.waze", 5)
        NavManeuverBus.clear("com.waze")
        assertNull(NavManeuverBus.latest("com.waze"))
    }

    @Test
    fun clearAfterServesDuringGraceThenStops() {
        NavManeuverBus.clear("com.waze")
        NavManeuverBus.set("com.waze", 7)
        // soft-clear with a 0 ms grace expires immediately (now >= deadline)
        NavManeuverBus.clearAfter("com.waze", 0L)
        assertNull(NavManeuverBus.latest("com.waze"))
        // a generous grace keeps serving the last code (set() resets the deadline)
        NavManeuverBus.set("com.waze", 8)
        NavManeuverBus.clearAfter("com.waze", 60_000L)
        assertEquals(8, NavManeuverBus.latest("com.waze"))
    }
}
