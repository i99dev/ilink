package com.i99dev.ilink.nav.logic

/**
 * The maneuver-icon catalog — codes 1..49, verbatim from the reference's
 * `HudController.TURN_ICON_*` / `getIconName`. Pure.
 *
 * Two consumers:
 *  - [amapIcon]: code → AutoNavi/Amap `NEW_ICON` for the broadcast transport
 *    (`mapTurnKindToAmapBroadcastIcon`, verbatim).
 *  - [glyph]: the 9 distinct drawn glyphs the SOME/IP icon renderer needs
 *    (49 codes collapse to 9 shapes — see [ManeuverGlyph]).
 *
 * Safety: a code outside 1..49 is NOT a maneuver — callers must SUPPRESS the
 * icon ([isValid] == false), never substitute "straight".
 */
object ManeuverCatalog {

    const val MIN = 1
    const val MAX = 49

    /** Default when a source can't classify the maneuver (the reference uses 11). */
    const val STRAIGHT = 11

    fun isValid(code: Int): Boolean = code in MIN..MAX

    /** The exact `TURN_ICON_*` name (diagnostics / provenance). */
    fun name(code: Int): String = NAMES[code] ?: "UNKNOWN ($code)"

    /** code → Amap broadcast NEW_ICON (`mapTurnKindToAmapBroadcastIcon`, verbatim). */
    fun amapIcon(code: Int): Int = when (code) {
        48 -> 12
        1, 7 -> 6
        2, 8 -> 4
        3, 4 -> 7
        5, 6 -> 3
        9, 10 -> 5
        11, 12 -> 2
        15, 16, 17, 18, 19, 20 -> 8
        else -> 2
    }

    // Huawei ADS HMI cluster (Di5.1 trims with com.huawei.hibaic.adshmiic) reads
    // the instrument-HAL GUIDE_ICON, whose value space is 1153..1182 — NOT our
    // maneuver codes. The factory bridge (com.byd.amapservice `b.a.a.a.b`) maps a
    // Petal maneuver id through two parallel tables: [F1297A] (petal → our code,
    // i.e. recommendedDrivingDirectionsId) and [F1298B] (petal → cluster GUIDE_ICON).
    // Our maneuver code IS the F1297A output, so cluster icon = F1298B[indexOf(F1297A, code)].
    private val F1297A = intArrayOf(
        0, 0, 1, 2, 3, 5, 7, 8, 9, 11, 45, 13, 24, 46, 47, 48, 49, 14, 23, 10, 12, 15, 18, 20, 22, 16, 17, 19, 21,
    )
    private val F1298B = intArrayOf(
        0, 1153, 1154, 1155, 1157, 1159, 1160, 1161, 1162, 1164, 1178, 1166, 1177, 1179, 1180, 1181, 1182,
        1167, 1176, 1163, 1165, 1168, 1171, 1173, 1175, 1169, 1170, 1172, 1174, 1156, 1158,
    )

    /** Our maneuver [code] → the Huawei cluster's instrument-HAL GUIDE_ICON value
     *  (1153..1182). 0 when there's no mapping (cluster shows no arrow). */
    fun huaweiClusterIcon(code: Int): Int {
        val i = F1297A.indexOf(code)
        return if (i in F1298B.indices) F1298B[i] else 0
    }

    /** Which of the 9 rendered glyphs a code draws (icon renderer caches these). */
    fun glyph(code: Int): ManeuverGlyph = when (code) {
        1, 7 -> ManeuverGlyph.LEFT
        2, 8 -> ManeuverGlyph.RIGHT
        3, 4 -> ManeuverGlyph.SLIGHT_LEFT
        5, 6 -> ManeuverGlyph.SLIGHT_RIGHT
        9 -> ManeuverGlyph.UTURN_LEFT
        10 -> ManeuverGlyph.UTURN_RIGHT
        12 -> ManeuverGlyph.DOTTED_STRAIGHT // depart (start of route) — distinct from continue-straight
        in 15..44 -> ManeuverGlyph.ROUNDABOUT // the whole roundabout family (was rendering as straight!)
        45, 48 -> ManeuverGlyph.PIN
        else -> ManeuverGlyph.STRAIGHT // 11 + all other defaults
    }

    private val NAMES: Map<Int, String> = mapOf(
        1 to "TURN_ICON_LEFT", 2 to "TURN_ICON_RIGHT",
        3 to "TURN_ICON_SLIGHT_LEFT", 4 to "TURN_ICON_SLIGHT_LEFT_ALT",
        5 to "TURN_ICON_SLIGHT_RIGHT", 6 to "TURN_ICON_SLIGHT_RIGHT_ALT",
        7 to "TURN_ICON_SHARP_LEFT", 8 to "TURN_ICON_SHARP_RIGHT",
        9 to "TURN_ICON_U_TURN_LEFT", 10 to "TURN_ICON_U_TURN_RIGHT",
        11 to "TURN_ICON_STRAIGHT_SOLID", 12 to "TURN_ICON_STRAIGHT_DOTTED",
        13 to "TURN_ICON_DETOUR_RIGHT", 14 to "TURN_ICON_DETOUR_LEFT",
        15 to "TURN_ICON_ROUNDABOUT_3_4_LEFT", 16 to "TURN_ICON_ROUNDABOUT_1_4_LEFT",
        17 to "TURN_ICON_ROUNDABOUT_3_4_RIGHT", 18 to "TURN_ICON_ROUNDABOUT_1_4_RIGHT",
        19 to "TURN_ICON_ROUNDABOUT_STRAIGHT_L", 20 to "TURN_ICON_ROUNDABOUT_STRAIGHT_R",
        21 to "TURN_ICON_ROUNDABOUT_L_TO_R", 22 to "TURN_ICON_ROUNDABOUT_R_TO_L",
        23 to "TURN_ICON_ROUNDABOUT_STRAIGHT_ALT1", 24 to "TURN_ICON_ROUNDABOUT_STRAIGHT_ALT2",
        25 to "TURN_ICON_ROUNDABOUT_CCW_1_LAP", 26 to "TURN_ICON_ROUNDABOUT_CCW_2_LAPS",
        27 to "TURN_ICON_ROUNDABOUT_CCW_3_LAPS", 28 to "TURN_ICON_ROUNDABOUT_CCW_4_LAPS",
        29 to "TURN_ICON_ROUNDABOUT_CCW_5_LAPS", 30 to "TURN_ICON_ROUNDABOUT_CCW_6_LAPS",
        31 to "TURN_ICON_ROUNDABOUT_CCW_7_LAPS", 32 to "TURN_ICON_ROUNDABOUT_CCW_8_LAPS",
        33 to "TURN_ICON_ROUNDABOUT_CCW_9_LAPS", 34 to "TURN_ICON_ROUNDABOUT_CCW_10_LAPS",
        35 to "TURN_ICON_ROUNDABOUT_CW_1_LAP", 36 to "TURN_ICON_ROUNDABOUT_CW_2_LAPS",
        37 to "TURN_ICON_ROUNDABOUT_CW_3_LAPS", 38 to "TURN_ICON_ROUNDABOUT_CW_4_LAPS",
        39 to "TURN_ICON_ROUNDABOUT_CW_5_LAPS", 40 to "TURN_ICON_ROUNDABOUT_CW_6_LAPS",
        41 to "TURN_ICON_ROUNDABOUT_CW_7_LAPS", 42 to "TURN_ICON_ROUNDABOUT_CW_8_LAPS",
        43 to "TURN_ICON_ROUNDABOUT_CW_9_LAPS", 44 to "TURN_ICON_ROUNDABOUT_CW_10_LAPS",
        45 to "TURN_ICON_STOP_LEFT", 46 to "TURN_ICON_PARKING_CAFE",
        47 to "TURN_ICON_TOLLBOOTH", 48 to "TURN_ICON_DESTINATION_CHINESE",
        49 to "TURN_ICON_TUNNEL",
    )
}

/** The 9 distinct shapes the 49 codes render to (icon renderer pre-caches these). */
enum class ManeuverGlyph { LEFT, RIGHT, SLIGHT_LEFT, SLIGHT_RIGHT, UTURN_LEFT, UTURN_RIGHT, STRAIGHT, DOTTED_STRAIGHT, ROUNDABOUT, PIN }
