package com.i99dev.ilink.nav.logic

import android.app.Notification
import android.content.Context

/**
 * Camera / safety / traffic-light alerts parsed from a Yandex Maps nav notification.
 *
 * Yandex puts NO alert in notification text — it encodes the alert in the **icon
 * drawable resource name** of an ImageView in the notification's RemoteViews
 * (`road_alerts_camera_*`, `road_alerts_accident_*`, …, `traffic_light_*`). The reference
 * (car-tested) reads those names and maps them to fixed BYD instrument codes; this is
 * a faithful port. Only Yandex needs this — Google Maps and Waze carry no alert icons.
 *
 * Distance (100) and state (2 = active) are the fixed placeholders the reference ships
 * (Yandex gives no alert distance). Codes: camera=1; safety other=1 / accident=10 /
 * road_works=11. Rendered via the BYD HAL [com.i99dev.ilink.nav.transport.canfid]
 * camera/safety setters (CAN-FID path; SOME/IP RoadInfo carries no alert field).
 */
data class NavAlerts(
    val cameraType: Int? = null,
    val cameraDistance: Int? = null,
    val cameraState: Int? = null,
    val safetyType: Int? = null,
    val safetyDistance: Int? = null,
    val safetyState: Int? = null,
    val trafficLightColor: String? = null,
    val trafficLightSeconds: String? = null,
) {
    val isEmpty: Boolean
        get() = cameraType == null && safetyType == null &&
            trafficLightColor == null && trafficLightSeconds == null
}

object NavAlertExtractor {
    private const val DIST = 100 // the reference placeholder — Yandex supplies no alert distance
    private const val STATE = 2  // active

    /** Scan the notification's icon resource names and classify alerts. */
    fun extract(pkg: String, notification: Notification, context: Context): NavAlerts =
        fromResourceNames(NavManeuverExtractor.resourceEntryNames(pkg, notification, context))

    /** Pure: icon resource-entry-names → alert fields (host-testable). */
    fun fromResourceNames(names: List<String>): NavAlerts {
        var cameraType: Int? = null
        var safetyType: Int? = null
        var light: String? = null
        for (raw in names) {
            val name = raw.lowercase()
            when {
                "road_alerts_camera" in name -> cameraType = 1
                "road_alerts_accident" in name -> safetyType = 10
                "road_alerts_road_works" in name -> safetyType = 11
                "road_alerts_other" in name -> safetyType = safetyType ?: 1
            }
            if ("traffic_light" in name) {
                when {
                    "red" in name -> light = "red"
                    "green" in name -> light = "green"
                    "yellow" in name -> light = "yellow"
                }
            }
        }
        return NavAlerts(
            cameraType = cameraType,
            cameraDistance = cameraType?.let { DIST },
            cameraState = cameraType?.let { STATE },
            safetyType = safetyType,
            safetyDistance = safetyType?.let { DIST },
            safetyState = safetyType?.let { STATE },
            trafficLightColor = light,
        )
    }
}
