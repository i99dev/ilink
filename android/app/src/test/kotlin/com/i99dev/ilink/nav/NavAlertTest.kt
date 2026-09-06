package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.logic.NavAlertExtractor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Host-JVM coverage for the Yandex alert icon-name → code mapping (P3). */
class NavAlertTest {

    @Test
    fun camera() {
        val a = NavAlertExtractor.fromResourceNames(listOf("road_alerts_camera_32"))
        assertEquals(1, a.cameraType)
        assertEquals(100, a.cameraDistance)
        assertEquals(2, a.cameraState)
        assertNull(a.safetyType)
    }

    @Test
    fun safetyKinds() {
        assertEquals(10, NavAlertExtractor.fromResourceNames(listOf("road_alerts_accident_32")).safetyType)
        assertEquals(11, NavAlertExtractor.fromResourceNames(listOf("road_alerts_road_works_32")).safetyType)
        assertEquals(1, NavAlertExtractor.fromResourceNames(listOf("road_alerts_other_32")).safetyType)
    }

    @Test
    fun trafficLightColor() {
        assertEquals("red", NavAlertExtractor.fromResourceNames(listOf("traffic_light_phase_red")).trafficLightColor)
        assertEquals("green", NavAlertExtractor.fromResourceNames(listOf("traffic_light_green_24")).trafficLightColor)
    }

    @Test
    fun unrelatedNamesYieldEmpty() {
        val a = NavAlertExtractor.fromResourceNames(listOf("ic_maneuver_turn_left", "primaryIcon", "logo"))
        assertTrue(a.isEmpty)
    }

    @Test
    fun emptyInput() {
        assertTrue(NavAlertExtractor.fromResourceNames(emptyList()).isEmpty)
    }
}
