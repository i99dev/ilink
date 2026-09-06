package com.i99dev.ilink.nav.logic

/**
 * Classifies a Waze alert (alerter popup text / contentDescription) into a
 * kind, then maps it to the cluster's camera/safety channel. Net-new feature —
 * the reference reads NO Waze alerts (its camera/safety fields are inert).
 *
 * Two clearly-separated parts:
 *  - [classify] — robust text → [WazeAlertKind] (Waze's documented alert taxonomy).
 *  - [BydAlertCodes] — kind → BYD instrument integer code. **PROVISIONAL**: the
 *    real BYD `cameraType`/`safetyType` code space is firmware-defined and
 *    UNVERIFIED — calibrate on-car with a glyph sweep. Only that table changes
 *    after calibration; the classifier + wire path stay.
 */
enum class WazeAlertKind {
    SPEED_CAMERA, RED_LIGHT, SPEED_AND_RED_LIGHT, AVERAGE_SPEED, DUMMY_CAMERA,
    POLICE, HAZARD, ACCIDENT, ROAD_CLOSURE,
}

object WazeAlertClassifier {
    fun classify(text: String?): WazeAlertKind? {
        val t = text?.lowercase()?.trim() ?: return null
        if (t.isEmpty()) return null
        return when {
            ("speed" in t || "radar" in t) && ("red" in t) -> WazeAlertKind.SPEED_AND_RED_LIGHT
            "red light" in t || "red-light" in t -> WazeAlertKind.RED_LIGHT
            "average" in t || "section" in t -> WazeAlertKind.AVERAGE_SPEED
            "dummy" in t || "fake" in t -> WazeAlertKind.DUMMY_CAMERA
            "camera" in t || "radar" in t || "speed cam" in t -> WazeAlertKind.SPEED_CAMERA
            "police" in t || "cop" in t -> WazeAlertKind.POLICE
            "accident" in t || "crash" in t -> WazeAlertKind.ACCIDENT
            "closure" in t || "closed" in t -> WazeAlertKind.ROAD_CLOSURE
            "hazard" in t || "object on road" in t || "pothole" in t -> WazeAlertKind.HAZARD
            else -> null
        }
    }

    /** Which cluster channel a kind drives. */
    fun isCamera(k: WazeAlertKind): Boolean = BydAlertCodes.cameraType(k) != null
}

/**
 * PROVISIONAL kind → BYD instrument code. The integer space belongs to BYD's
 * `BYDAutoInstrumentDevice` firmware (no public table; the reference only passes through
 * Yandex's values). **Calibrate on-car**: feed `sendCameraGuidanceInfo(N,200,0)`
 * for N=1..~20 and observe the rendered glyph, then fix this table.
 */
object BydAlertCodes {
    fun cameraType(k: WazeAlertKind): Int? = when (k) {
        WazeAlertKind.SPEED_CAMERA -> 1
        WazeAlertKind.RED_LIGHT -> 2
        WazeAlertKind.SPEED_AND_RED_LIGHT -> 3
        WazeAlertKind.AVERAGE_SPEED -> 4
        WazeAlertKind.DUMMY_CAMERA -> 5
        else -> null
    }

    fun safetyType(k: WazeAlertKind): Int? = when (k) {
        WazeAlertKind.POLICE -> 1
        WazeAlertKind.HAZARD -> 2
        WazeAlertKind.ACCIDENT -> 3
        WazeAlertKind.ROAD_CLOSURE -> 4
        else -> null
    }
}
