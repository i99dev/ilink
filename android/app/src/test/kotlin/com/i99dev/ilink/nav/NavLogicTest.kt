package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.logic.HudTextSanitizer
import com.i99dev.ilink.nav.logic.ManeuverCatalog
import com.i99dev.ilink.nav.logic.ManeuverGlyph
import com.i99dev.ilink.nav.logic.ManeuverTextMap
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.logic.NavFormat
import com.i99dev.ilink.nav.logic.NavManeuverExtractor
import com.i99dev.ilink.nav.logic.NavNotifParse
import com.i99dev.ilink.nav.logic.NavTextParse
import com.i99dev.ilink.nav.logic.SomeIpGuideLine
import com.i99dev.ilink.nav.logic.BydAlertCodes
import com.i99dev.ilink.nav.logic.WazeAlertClassifier
import com.i99dev.ilink.nav.logic.WazeAlertKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Host-JVM coverage for the pure rendering/format logic. */
class NavLogicTest {

    // ---- ManeuverCatalog ----

    @Test
    fun catalogAmapAndGlyphMapping() {
        assertEquals(12, ManeuverCatalog.amapIcon(48))
        assertEquals(6, ManeuverCatalog.amapIcon(1))
        assertEquals(6, ManeuverCatalog.amapIcon(7))
        assertEquals(4, ManeuverCatalog.amapIcon(2))
        assertEquals(8, ManeuverCatalog.amapIcon(16))
        assertEquals(2, ManeuverCatalog.amapIcon(99)) // default
        assertEquals(ManeuverGlyph.LEFT, ManeuverCatalog.glyph(7))
        assertEquals(ManeuverGlyph.SLIGHT_RIGHT, ManeuverCatalog.glyph(6))
        assertEquals(ManeuverGlyph.PIN, ManeuverCatalog.glyph(48))
        assertEquals(ManeuverGlyph.ROUNDABOUT, ManeuverCatalog.glyph(30)) // 30 is a roundabout code
        // code 12 (depart) is now a distinct dotted-straight glyph; 11 stays solid
        assertEquals(ManeuverGlyph.DOTTED_STRAIGHT, ManeuverCatalog.glyph(12))
        assertEquals(ManeuverGlyph.STRAIGHT, ManeuverCatalog.glyph(11))
        // the roundabout family (15..44) now renders a roundabout, not a straight arrow
        assertEquals(ManeuverGlyph.ROUNDABOUT, ManeuverCatalog.glyph(20))
        assertEquals(ManeuverGlyph.ROUNDABOUT, ManeuverCatalog.glyph(35))
        assertTrue(ManeuverCatalog.isValid(49))
        assertTrue(!ManeuverCatalog.isValid(50))
    }

    @Test
    fun catalogHuaweiClusterIconMapping() {
        // Our maneuver code → Huawei ADS HMI cluster GUIDE_ICON (1153..1182),
        // via the factory f1297a/f1298b tables.
        assertEquals(1154, ManeuverCatalog.huaweiClusterIcon(1))  // turn left
        assertEquals(1155, ManeuverCatalog.huaweiClusterIcon(2))  // turn right
        assertEquals(1164, ManeuverCatalog.huaweiClusterIcon(11)) // straight
        assertEquals(1178, ManeuverCatalog.huaweiClusterIcon(45)) // arrive/destination
        assertEquals(1157, ManeuverCatalog.huaweiClusterIcon(3))  // slight left
        assertEquals(0, ManeuverCatalog.huaweiClusterIcon(999))   // unmapped → no arrow
        assertEquals("TURN_ICON_DESTINATION_CHINESE", ManeuverCatalog.name(48))
    }

    // ---- SomeIpGuideLine ----

    private fun lons(s: String): List<Double> =
        Regex("""\[(-?[0-9.]+),(-?[0-9.]+),0]""").findAll(s).map { it.groupValues[1].toDouble() }.toList()

    private fun lats(s: String): List<Double> =
        Regex("""\[(-?[0-9.]+),(-?[0-9.]+),0]""").findAll(s).map { it.groupValues[2].toDouble() }.toList()

    /**
     * **TASK-005 — this test was deliberately inverted in scope.** It was written
     * against the Beijing stub when the stub WAS the behaviour; it now pins the
     * stub as the **no-position fallback** only (note the explicit `null, null,
     * null`). Left as a drift guard on that fallback rather than deleted, because
     * "no fix / no permission emits the old wire" is a real requirement — but it
     * is no longer a description of what the HUD does on a car with a GPS fix.
     * The real projection lives in `NavGuideLineTest`; do not extend this one.
     */
    @Test
    fun guideLineFallbackShapePerManeuverFamily() {
        val straight = SomeIpGuideLine.build(11, null, null, null)
        assertEquals(10, lons(straight).size)
        assertTrue("straight: every lon == anchor", lons(straight).all { it == 116.4074 })
        // lat marches strictly north
        val la = lats(straight)
        assertTrue("lat increasing", (1 until la.size).all { la[it] > la[it - 1] })

        val left = SomeIpGuideLine.build(1, null, null, null)
        val right = SomeIpGuideLine.build(2, null, null, null)
        assertNotEquals(straight, left)
        assertTrue("left bends west (lon decreases)", lons(left).last() < 116.4074)
        assertTrue("right bends east (lon increases)", lons(right).last() > 116.4074)
        // first 6 points have no bend (off=0) in both families
        assertEquals(116.4074, lons(left)[5], 1e-9)
    }

    // ---- NavFormat ----

    @Test
    fun distanceAndTimeFormat() {
        assertEquals("750 m", NavFormat.distance(750))
        assertEquals("999 m", NavFormat.distance(999))
        assertEquals("1.5 km", NavFormat.distance(1500))
        assertEquals("12.3 km", NavFormat.distance(12345))
        assertEquals("45 min", NavFormat.time(2700))
        assertEquals("0 min", NavFormat.time(30))
        assertEquals("2h 5m", NavFormat.time(7500))
    }

    // ---- HudTextSanitizer (fallback path runs on host) ----

    @Test
    fun sanitizerStripsDiacriticsAndPreservesCjk() {
        assertEquals("Cafe", HudTextSanitizer.fallback("Café"))
        assertEquals("Pena", HudTextSanitizer.fallback("Peña"))
        // CJK preserved verbatim; ASCII passes; trimmed
        assertEquals("北京路", HudTextSanitizer.sanitize("  北京路  "))
        assertTrue(HudTextSanitizer.isCjk('京'))
        assertTrue(!HudTextSanitizer.isCjk('A'))
        assertEquals("", HudTextSanitizer.sanitize(null))
        assertEquals("", HudTextSanitizer.sanitize("   "))
    }

    // ---- ManeuverTextMap ----

    @Test
    fun textMapClassifiesManeuvers() {
        assertEquals(11, ManeuverTextMap.classify(""))       // blank → straight
        assertEquals(11, ManeuverTextMap.classify("   "))
        assertEquals(2, ManeuverTextMap.classify("Turn right"))
        assertEquals(1, ManeuverTextMap.classify("Turn left")) // explicit "left" → 1
        assertEquals(3, ManeuverTextMap.classify("Slight left"))
        assertEquals(5, ManeuverTextMap.classify("keep right"))
        assertEquals(7, ManeuverTextMap.classify("Sharp left"))
        assertEquals(8, ManeuverTextMap.classify("sharp right"))
        assertEquals(9, ManeuverTextMap.classify("Make a U-Turn"))
        assertEquals(20, ManeuverTextMap.classify("Enter the roundabout"))
        assertEquals(48, ManeuverTextMap.classify("You have arrived — done"))
        // Unknown maneuver → STRAIGHT (11), never a confident LEFT. This is the
        // "always left" fix: an unclassifiable string no longer renders a left arrow.
        assertEquals(11, ManeuverTextMap.classify("Head north"))
        // Cyrillic EQUALS extra
        assertEquals(2, ManeuverTextMap.classify("направо"))
        // the production exit-order fix: "exit 10" must NOT match "exit 1"
        assertEquals(34, ManeuverTextMap.classify("Take exit 10"))
        assertEquals(25, ManeuverTextMap.classify("Take exit 1"))
        assertEquals(30, ManeuverTextMap.classify("sixth exit"))
    }

    @Test
    fun classifiesManeuverIconResourceNames() {
        // The notification large-icon arrow names (underscored) classify to the
        // PRECISE variant, not generic left/right. Covers turn_*, ramp_*, etc.
        assertEquals(1, ManeuverTextMap.classify("maneuver_turn_normal_left"))
        assertEquals(2, ManeuverTextMap.classify("maneuver_turn_normal_right"))
        assertEquals(7, ManeuverTextMap.classify("maneuver_turn_sharp_left"))
        assertEquals(8, ManeuverTextMap.classify("maneuver_turn_sharp_right"))
        assertEquals(3, ManeuverTextMap.classify("maneuver_turn_slight_left"))
        assertEquals(5, ManeuverTextMap.classify("maneuver_turn_slight_right"))
        assertEquals(3, ManeuverTextMap.classify("maneuver_keep_left"))
        assertEquals(5, ManeuverTextMap.classify("maneuver_keep_right"))
        assertEquals(9, ManeuverTextMap.classify("maneuver_u_turn_left"))
        assertEquals(7, ManeuverTextMap.classify("maneuver_on_ramp_sharp_left"))
        assertEquals(5, ManeuverTextMap.classify("maneuver_off_ramp_slight_right"))
        assertEquals(20, ManeuverTextMap.classify("maneuver_roundabout_enter_cw"))
        assertEquals(11, ManeuverTextMap.classify("maneuver_straight"))
        assertEquals(12, ManeuverTextMap.classify("maneuver_depart")) // depart glyph (straight)
    }

    @Test
    fun textMapClassifiesUturnTollTunnelDestinationDepart() {
        // directional u-turn no longer collapses to left-u-turn
        assertEquals(10, ManeuverTextMap.classify("Make a U-turn right"))
        assertEquals(9, ManeuverTextMap.classify("Make a U-turn")) // unchanged
        // toll + tunnel
        assertEquals(47, ManeuverTextMap.classify("Toll booth ahead"))
        assertEquals(47, ManeuverTextMap.classify("tolbooth"))
        assertEquals(49, ManeuverTextMap.classify("Enter tunnel"))
        // destination + depart icon names
        assertEquals(45, ManeuverTextMap.classify("maneuver_destination_left"))
        assertEquals(45, ManeuverTextMap.classify("maneuver_destination_right"))
        assertEquals(12, ManeuverTextMap.classify("maneuver_depart"))
        // CRITICAL: a real turn that merely MENTIONS a special word stays the turn.
        assertEquals(2, ManeuverTextMap.classify("Turn right toward the toll plaza"))
        assertEquals(1, ManeuverTextMap.classify("Turn left, then your destination is ahead"))
    }

    // ---- NavTextParse (universal distance/time extraction) ----

    @Test
    fun textParseDistanceAndTime() {
        assertEquals(750, NavTextParse.distanceMeters("750 m"))
        assertEquals(200, NavTextParse.distanceMeters("In 200 m, turn left onto Main St"))
        assertEquals(1500, NavTextParse.distanceMeters("1.5 km"))
        assertEquals(2300, NavTextParse.distanceMeters("2,3 km"))
        assertEquals(482, NavTextParse.distanceMeters("0.3 mi"))
        assertNull(NavTextParse.distanceMeters("no distance"))
        assertNull(NavTextParse.distanceMeters(null))

        assertEquals(2700, NavTextParse.timeSeconds("45 min"))
        assertEquals(7500, NavTextParse.timeSeconds("2 h 5 min"))
        // combined ETA line "18 min · 12 km": time + distance independent
        assertEquals(1080, NavTextParse.timeSeconds("18 min · 12 km"))
        assertEquals(12000, NavTextParse.distanceMeters("18 min · 12 km"))
        // a bare distance must NOT be read as minutes
        assertNull(NavTextParse.timeSeconds("750 m"))
    }

    @Test
    fun textParseArabicNumeralsAndUnits() {
        // Google Maps (and others) in an Arabic locale render Arabic-Indic digits
        // + Arabic unit words — fold both, else the app is never detected.
        assertEquals(90, NavTextParse.distanceMeters("٩٠ متر")) // 90 m
        assertEquals(1500, NavTextParse.distanceMeters("١٫٥ كم")) // 1.5 km (Arabic decimal)
        assertEquals(2000, NavTextParse.distanceMeters("٢ كيلومتر")) // 2 km (full word)
        // embedded + followed by Arabic punctuation must still match
        assertEquals(300, NavTextParse.distanceMeters("في ٣٠٠ متر، انعطف يميناً"))
        // Extended/Persian Arabic-Indic digits fold too
        assertEquals(500, NavTextParse.distanceMeters("۵۰۰ متر"))
        // ETA: Arabic minutes + hours
        assertEquals(2700, NavTextParse.timeSeconds("٤٥ دقيقة")) // 45 min
        assertEquals(7500, NavTextParse.timeSeconds("٢ ساعة ٥ دقائق")) // 2 h 5 min
        // all-ASCII input is unaffected (fast-path no-op)
        assertEquals(750, NavTextParse.distanceMeters("750 m"))
    }

    @Test
    fun textParseDistanceUnitsFeetYardsChineseAndIntegerMetres() {
        assertEquals(152, NavTextParse.distanceMeters("500 ft")) // 500 * 0.3048
        assertEquals(91, NavTextParse.distanceMeters("100 yd")) // 100 * 0.9144
        assertEquals(500, NavTextParse.distanceMeters("500 米")) // Chinese metre
        // metres are integer-only: a decimal metre is rejected (not rounded to 0)
        assertNull(NavTextParse.distanceMeters("0.4 m"))
        assertNull(NavTextParse.distanceMeters("1.5 m"))
        assertEquals(2, NavTextParse.distanceMeters("2 m")) // integer metres OK
        // km / mi decimals still work (regression)
        assertEquals(1500, NavTextParse.distanceMeters("1.5 km"))
        assertEquals(482, NavTextParse.distanceMeters("0.3 mi"))
    }

    // ---- NavNotifParse (universal "support most maps" notification parser) ----

    @Test
    fun notifParseGoogleMapsStyle() {
        val g = NavNotifParse.parse(
            title = "Turn left onto Main St",
            text = "500 m",
            subText = "25 min · 12 km",
            bigText = null,
            source = NavSourceId.GOOGLE_MAPS,
        )
        assertNotNull(g)
        assertEquals(1, g!!.maneuverIcon)          // generic left → 1
        assertEquals(500, g.distanceMeters)
        assertEquals("Main St", g.roadName)        // "onto" heuristic
        assertEquals(1500, g.remainingTimeSeconds)
        assertEquals(12000, g.remainingDistanceMeters)
        assertEquals(NavSourceId.GOOGLE_MAPS, g.source)
    }

    @Test
    fun notifParseManeuverAndDistanceAnyField() {
        // distance in the title (Waze-ish), right turn
        val w = NavNotifParse.parse("In 300 m, turn right", "12 min to destination", null, null, NavSourceId.WAZE)
        assertNotNull(w)
        assertEquals(2, w!!.maneuverIcon)
        assertEquals(300, w.distanceMeters)
        assertEquals(720, w.remainingTimeSeconds)
        // no maneuver distance anywhere → not a nav frame
        assertNull(NavNotifParse.parse("Arrived at destination", null, null, null, NavSourceId.WAZE))
    }

    @Test
    fun roadFromHeuristic() {
        assertEquals("Elm Road", NavNotifParse.roadFrom("Head toward Elm Road"))
        assertEquals("A4", NavNotifParse.roadFrom("Keep right onto A4"))
    }

    @Test
    fun roadFromRejectsDistanceEtaAndManeuverText() {
        // Trailing ETA clock stripped off the street.
        assertEquals("Main St", NavNotifParse.roadFrom("Turn left onto Main St - 2:45 PM"))
        // Distance-only / maneuver-only / ETA-line are NOT streets → null (cluster
        // road stays empty instead of painting a distance or an ETA).
        assertNull("distance-only is not a road", NavNotifParse.roadFrom("500 m"))
        assertNull("bare maneuver is not a road", NavNotifParse.roadFrom("Continue"))
        assertNull("ETA line is not a road", NavNotifParse.roadFrom("5 min · 1.2 km"))
        assertNull("clock is not a road", NavNotifParse.roadFrom("14:30"))
    }

    @Test
    fun notifParseArrivalAcceptedAndDistanceCascadesToSubText() {
        // arrival with no distance anywhere → accepted, pin icon (48), distance 0.
        val a = NavNotifParse.parse("You have arrived — done", null, null, null, NavSourceId.WAZE)
        assertNotNull(a)
        assertEquals(48, a!!.maneuverIcon)
        assertEquals(0, a.distanceMeters)
        // distance only in subText (Yandex-style) is now honoured (cascade).
        val y = NavNotifParse.parse("Turn left", null, "500 m", null, NavSourceId.YANDEX)
        assertNotNull(y)
        assertEquals(500, y!!.distanceMeters)
        assertEquals(1, y.maneuverIcon)
        // a non-arrival with no distance anywhere is still rejected.
        assertNull(NavNotifParse.parse("Continue on Main St", null, null, null, NavSourceId.GOOGLE_MAPS))
    }

    @Test
    fun roadFromAcceptsDirectionNamedStreetsAndRejectsStatusLines() {
        // a street that *starts* with a direction word is valid post-separator.
        assertEquals("Toward Road", NavNotifParse.roadFrom("Turn left toward Toward Road"))
        assertEquals("Onto Street", NavNotifParse.roadFrom("Turn right onto Onto Street"))
        // a full maneuver-status line with no real separator yields no street.
        assertNull(NavNotifParse.roadFrom("Head to Main St"))
    }

    @Test
    fun customLayoutArrowNamesClassify() {
        // The RemoteViews path resolves a drawable NAME then classifies it as text.
        // The reflection/RV walk is covered on-car; here we lock the name→code
        // contract the path depends on (maneuver-balloon + generic arrow names).
        assertEquals(3, ManeuverTextMap.classify("notification_slight_left_sdl"))
        assertEquals(2, ManeuverTextMap.classify("notification_right_sdl"))
        assertEquals(1, ManeuverTextMap.classify("ic_arrow_turn_left"))
    }

    // ---- NavManeuverExtractor (title path — host-testable) ----

    @Test
    fun extractorStripsLeadingDistanceForms() {
        assertEquals("Turn left", NavManeuverExtractor.stripLeadingDistance("In 500 m, Turn left"))
        assertEquals("Turn right", NavManeuverExtractor.stripLeadingDistance("500 m – Turn right"))
        assertEquals("Keep left", NavManeuverExtractor.stripLeadingDistance("1,2 km · Keep left"))
        assertEquals("Sharp left", NavManeuverExtractor.stripLeadingDistance("0.3 mi — Sharp left"))
        assertEquals("Turn right", NavManeuverExtractor.stripLeadingDistance("Turn right")) // unchanged
    }

    @Test
    fun extractorClassifiesTitleDirection() {
        // The bug case: a real direction in the title is honoured (not defaulted).
        assertEquals(1, NavManeuverExtractor.extractFromTitle("In 500 m, turn left onto Main St"))
        assertEquals(2, NavManeuverExtractor.extractFromTitle("300 m – Turn right"))
        assertEquals(3, NavManeuverExtractor.extractFromTitle("Slight left"))
        assertEquals(8, NavManeuverExtractor.extractFromTitle("Sharp right onto A4"))
        assertEquals(9, NavManeuverExtractor.extractFromTitle("Make a U-turn"))
        assertEquals(20, NavManeuverExtractor.extractFromTitle("Enter the roundabout"))
        // No turn word → null (so the large-icon step can try), NOT STRAIGHT.
        assertNull(NavManeuverExtractor.extractFromTitle("Continue on Main St"))
        assertNull(NavManeuverExtractor.extractFromTitle("Head north"))
        assertNull(NavManeuverExtractor.extractFromTitle(""))
        assertNull(NavManeuverExtractor.extractFromTitle(null))
    }

    // ---- NavNotifParse maneuver override (notification is the authority) ----

    @Test
    fun notifParseUsesManeuverOverride() {
        // The icon-derived code wins over the text classify (text → 2, override 7).
        val g = NavNotifParse.parse(
            title = "Turn right onto Main St",
            text = "500 m",
            subText = null,
            bigText = null,
            source = NavSourceId.GOOGLE_MAPS,
            maneuverOverride = 7,
        )
        assertNotNull(g)
        assertEquals(7, g!!.maneuverIcon)
        assertEquals("Main St", g.roadName)
        assertEquals(500, g.distanceMeters)
    }

    @Test
    fun notifParseIgnoresInvalidOverrideAndFallsBackToText() {
        // Out-of-range override must not poison the frame — fall back to text.
        val g = NavNotifParse.parse(
            "Turn left onto Elm Rd", "200 m", null, null,
            NavSourceId.GOOGLE_MAPS, maneuverOverride = 0,
        )
        assertNotNull(g)
        assertEquals(1, g!!.maneuverIcon) // text "left" → 1, override 0 ignored
        val g2 = NavNotifParse.parse(
            "Turn left onto Elm Rd", "200 m", null, null,
            NavSourceId.GOOGLE_MAPS, maneuverOverride = null,
        )
        assertEquals(1, g2!!.maneuverIcon)
    }

    // ---- WazeAlertClassifier (camera/police alerts → cluster glyph) ----

    @Test
    fun wazeAlertClassification() {
        assertEquals(WazeAlertKind.SPEED_CAMERA, WazeAlertClassifier.classify("Speed camera ahead"))
        assertEquals(WazeAlertKind.RED_LIGHT, WazeAlertClassifier.classify("Red light camera"))
        assertEquals(WazeAlertKind.AVERAGE_SPEED, WazeAlertClassifier.classify("Average speed check"))
        assertEquals(WazeAlertKind.POLICE, WazeAlertClassifier.classify("Police reported ahead"))
        assertEquals(WazeAlertKind.HAZARD, WazeAlertClassifier.classify("Object on road"))
        assertNull(WazeAlertClassifier.classify("Heavy traffic"))
        assertNull(WazeAlertClassifier.classify(null))
        // routed to the right cluster channel (codes provisional, calibrate on-car)
        assertEquals(1, BydAlertCodes.cameraType(WazeAlertKind.SPEED_CAMERA))
        assertNull(BydAlertCodes.cameraType(WazeAlertKind.POLICE))
        assertEquals(1, BydAlertCodes.safetyType(WazeAlertKind.POLICE))
    }
}
