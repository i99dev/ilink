package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.domain.NavFix
import com.i99dev.ilink.nav.logic.SomeIpGuideLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * TASK-005 — the guide-line projection, tested **as maths**.
 *
 * The thing being fixed is structural: the old builder added raw degrees to both
 * axes from a hardcoded Beijing anchor, so its "22 m" steps were only ever the
 * right size near the equator and its direction was always north. Comparing
 * strings cannot catch that, so everything here is asserted with an INDEPENDENT
 * geodesy implementation ([haversineMeters] / [bearingDegrees], textbook
 * spherical formulas) rather than by re-deriving the production maths.
 *
 * Every distance/bearing assertion runs at **three latitudes** — equator, ~24°
 * (UAE, our actual fleet) and ~56° (high latitude) — because a test that only
 * passes at one latitude IS the bug this task fixes.
 *
 * Note the ~4 cm tolerance on the 22 m step: production uses
 * [SomeIpGuideLine.METERS_PER_DEG_LAT] = 111 000 (R ≈ 6 359 832 m) while the
 * checker below uses the conventional mean radius 6 371 000 m — a 0.18 % model
 * difference, i.e. ±0.04 m over a 22 m step. Irrelevant for a 200 m HUD stub, but
 * it must not be papered over with a loose tolerance, hence the explicit
 * [stepsAreUniform] check which is radius-independent.
 */
class NavGuideLineTest {

    private companion object {
        const val EARTH_R = 6_371_000.0

        /** Equator, UAE (Dubai), high latitude (Moscow). */
        val LATITUDES = listOf(0.0, 24.4539, 55.7558)

        const val LEFT_CODE = 1
        const val RIGHT_CODE = 2
        const val STRAIGHT_CODE = 11

        // Frozen pre-TASK-005 output. `Double.toString` noise and all — note
        // `39.905800000000006`, the tell that this is a real capture and not a
        // re-derivation. Never regenerate these to make a test go green.
        const val FROZEN_STRAIGHT =
            "[[116.4074,39.9042,0],[116.4074,39.9044,0],[116.4074,39.9046,0]," +
                "[116.4074,39.9048,0],[116.4074,39.905,0],[116.4074,39.9052,0]," +
                "[116.4074,39.9054,0],[116.4074,39.9056,0]," +
                "[116.4074,39.905800000000006,0],[116.4074,39.906000000000006,0]]"
        const val FROZEN_LEFT =
            "[[116.4074,39.9042,0],[116.4074,39.9044,0],[116.4074,39.9046,0]," +
                "[116.4074,39.9048,0],[116.4074,39.905,0],[116.4074,39.9052,0]," +
                "[116.40719999999999,39.9054,0],[116.407,39.9056,0]," +
                "[116.40679999999999,39.905800000000006,0],[116.4066,39.906000000000006,0]]"
        const val FROZEN_RIGHT =
            "[[116.4074,39.9042,0],[116.4074,39.9044,0],[116.4074,39.9046,0]," +
                "[116.4074,39.9048,0],[116.4074,39.905,0],[116.4074,39.9052,0]," +
                "[116.4076,39.9054,0],[116.4078,39.9056,0]," +
                "[116.408,39.905800000000006,0],[116.4082,39.906000000000006,0]]"
    }

    // ---- independent geodesy (NOT the production model) ----

    private fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dp = Math.toRadians(lat2 - lat1)
        val dl = Math.toRadians(lon2 - lon1)
        val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * EARTH_R * atan2(sqrt(a), sqrt(1 - a))
    }

    /** Initial great-circle bearing, degrees clockwise from true north, 0..360. */
    private fun bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dl = Math.toRadians(lon2 - lon1)
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (Math.toDegrees(atan2(y, x)) + 360.0) % 360.0
    }

    /** Signed smallest angle from [a] to [b], −180..180. */
    private fun angleDelta(a: Double, b: Double): Double = ((b - a + 540.0) % 360.0) - 180.0

    // ---- string parsing (proves build() and points() agree) ----

    private val pointRe = Regex("""\[(-?[0-9.]+),(-?[0-9.]+),0]""")

    /** Parsed as [lon, lat] pairs, same order as [SomeIpGuideLine.points]. */
    private fun parse(s: String): List<DoubleArray> =
        pointRe.findAll(s).map { doubleArrayOf(it.groupValues[1].toDouble(), it.groupValues[2].toDouble()) }.toList()

    // =====================================================================
    // 1. step length — the core invariant, at every latitude
    // =====================================================================

    @Test
    fun consecutivePointsAre22MetresApartAtEveryLatitude() {
        for (lat in LATITUDES) {
            for (heading in listOf(0.0, 45.0, 90.0, 180.0, 217.0, 359.0)) {
                for (code in listOf(STRAIGHT_CODE, LEFT_CODE, RIGHT_CODE)) {
                    val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, heading), code)
                    assertEquals("point count @lat=$lat", SomeIpGuideLine.POINTS, pts.size)
                    for (i in 1 until pts.size) {
                        val d = haversineMeters(pts[i - 1][1], pts[i - 1][0], pts[i][1], pts[i][0])
                        assertEquals(
                            "segment $i @lat=$lat heading=$heading code=$code is $d m, expected 22 m",
                            SomeIpGuideLine.STEP_METERS, d, 0.05,
                        )
                    }
                }
            }
        }
    }

    /**
     * Radius-model-independent companion to the above: whatever the absolute
     * scale, every segment must be the SAME length. A projection that forgot the
     * cos(lat) term produces segments that grow or shrink as the line marches
     * north, so this fails loudly on the original bug even with a huge tolerance
     * on the absolute distance.
     */
    @Test
    fun stepsAreUniform() {
        for (lat in LATITUDES) {
            val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, 30.0), RIGHT_CODE)
            val lengths = (1 until pts.size).map {
                haversineMeters(pts[it - 1][1], pts[it - 1][0], pts[it][1], pts[it][0])
            }
            val first = lengths.first()
            for ((i, l) in lengths.withIndex()) {
                assertEquals("segment ${i + 1} @lat=$lat differs from segment 1", first, l, 0.01)
            }
        }
    }

    /** The formatted string must carry the same geometry as [points], within the
     *  6-decimal rounding (~0.11 m per coordinate). */
    @Test
    fun formattedStringMatchesTheComputedPoints() {
        for (lat in LATITUDES) {
            val fix = NavFix(lat, 55.2708, 42.0)
            val pts = SomeIpGuideLine.points(fix, LEFT_CODE)
            val parsed = parse(SomeIpGuideLine.build(LEFT_CODE, fix.lat, fix.lon, fix.heading))
            assertEquals(pts.size, parsed.size)
            for (i in pts.indices) {
                assertEquals("lon[$i] @lat=$lat", pts[i][0], parsed[i][0], 1e-6)
                assertEquals("lat[$i] @lat=$lat", pts[i][1], parsed[i][1], 1e-6)
            }
        }
    }

    // =====================================================================
    // 2. THE BUG: longitude scaling by cos(lat)
    // =====================================================================

    /**
     * Drive due east and measure the longitude delta per 22 m step. It must be
     * `22 / (111000 * cos(lat))` — i.e. the SAME ground distance costs more
     * degrees of longitude the further you are from the equator. The pre-TASK-005
     * builder used a constant degree step for both axes, which is this test's
     * `equatorStep` at every latitude on earth.
     */
    @Test
    fun longitudeStepScalesByCosLat() {
        val expectedAtEquator = SomeIpGuideLine.STEP_METERS / SomeIpGuideLine.METERS_PER_DEG_LAT

        for (lat in LATITUDES) {
            val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, 90.0), STRAIGHT_CODE)
            val dLon = pts[1][0] - pts[0][0]
            val expected = expectedAtEquator / cos(Math.toRadians(lat))
            assertEquals("lon step @lat=$lat", expected, dLon, 1e-12)
            // Heading is due east, so latitude must not move at all.
            assertEquals("lat must not drift on a due-east run @lat=$lat", pts[0][1], pts[9][1], 1e-12)
        }
    }

    /**
     * The headline number, stated the way the task states it: at ~56° a degree of
     * longitude is ~57 % of a degree of latitude, so covering the same 22 m east
     * takes ~1.75x more degrees than at the equator.
     */
    @Test
    fun aDegreeOfLongitudeIsAbout57PercentAt56Degrees() {
        val lat = 55.7558
        fun eastStep(l: Double): Double {
            val p = SomeIpGuideLine.points(NavFix(l, 55.2708, 90.0), STRAIGHT_CODE)
            return p[1][0] - p[0][0]
        }
        val ratio = eastStep(0.0) / eastStep(lat)
        assertEquals("ratio must be cos(lat)", cos(Math.toRadians(lat)), ratio, 1e-9)
        assertTrue("expected ~0.56-0.57, got $ratio", ratio > 0.55 && ratio < 0.58)

        // The structural bug, asserted directly: at this latitude the longitude
        // step CANNOT equal the latitude step for the same ground distance.
        val northStep = SomeIpGuideLine.points(NavFix(lat, 55.2708, 0.0), STRAIGHT_CODE)
            .let { it[1][1] - it[0][1] }
        val eastStepHere = eastStep(lat)
        assertTrue(
            "lon step ($eastStepHere) equals lat step ($northStep) at lat=$lat — " +
                "the cos(lat) scaling is missing, which is exactly the TASK-005 bug",
            abs(eastStepHere - northStep) / northStep > 0.5,
        )
        // ...whereas at the equator they DO coincide (the only place the old code
        // was ever right).
        val eqNorth = SomeIpGuideLine.points(NavFix(0.0, 55.2708, 0.0), STRAIGHT_CODE)
            .let { it[1][1] - it[0][1] }
        assertEquals(eqNorth, eastStep(0.0), 1e-12)
    }

    /** Latitude steps, by contrast, are latitude-INDEPENDENT. */
    @Test
    fun latitudeStepIsConstantEverywhere() {
        val expected = SomeIpGuideLine.STEP_METERS / SomeIpGuideLine.METERS_PER_DEG_LAT
        for (lat in LATITUDES) {
            val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, 0.0), STRAIGHT_CODE)
            assertEquals("lat step @lat=$lat", expected, pts[1][1] - pts[0][1], 1e-12)
        }
    }

    // =====================================================================
    // 3. heading is respected
    // =====================================================================

    /** The straight run (points 0..5) must point where the car points. */
    @Test
    fun headingRotatesThePolyline() {
        for (lat in LATITUDES) {
            for (heading in listOf(0.0, 37.0, 90.0, 180.0, 275.0)) {
                val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, heading), STRAIGHT_CODE)
                val b = bearingDegrees(pts[0][1], pts[0][0], pts[5][1], pts[5][0])
                assertEquals(
                    "polyline bearing @lat=$lat should follow heading $heading but was $b",
                    0.0, angleDelta(heading, b), 0.2,
                )
            }
        }
    }

    /** No bearing on the fix (stationary car / network-only fix) → head north,
     *  which is what the old stub did. Never NaN, never a random direction. */
    @Test
    fun nullHeadingHeadsNorth() {
        val pts = SomeIpGuideLine.points(NavFix(24.4539, 55.2708, null), STRAIGHT_CODE)
        assertEquals(0.0, angleDelta(0.0, bearingDegrees(pts[0][1], pts[0][0], pts[5][1], pts[5][0])), 0.2)
        assertTrue("longitude must not drift heading north", abs(pts[5][0] - pts[0][0]) < 1e-9)
    }

    /** A non-finite bearing from a broken provider must not poison the trig. */
    @Test
    fun nonFiniteHeadingIsTreatedAsNorth() {
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val pts = SomeIpGuideLine.points(NavFix(24.4539, 55.2708, bad), STRAIGHT_CODE)
            assertTrue("NaN/Inf leaked into the polyline", pts.all { it[0].isFinite() && it[1].isFinite() })
            assertEquals(0.0, angleDelta(0.0, bearingDegrees(pts[0][1], pts[0][0], pts[5][1], pts[5][0])), 0.2)
        }
    }

    // =====================================================================
    // 4. bend shape + direction per maneuver family
    // =====================================================================

    /** Points 0..5 straight, then 15° more per step — measured, not assumed. */
    @Test
    fun bendIs15DegreesPerStepAfterPoint5() {
        val heading = 30.0
        for (lat in LATITUDES) {
            for (code in listOf(LEFT_CODE, RIGHT_CODE)) {
                val sign = SomeIpGuideLine.turnSign(code)
                val pts = SomeIpGuideLine.points(NavFix(lat, 55.2708, heading), code)
                for (i in 1 until pts.size) {
                    val bendSteps = if (i <= SomeIpGuideLine.BEND_FROM_INDEX) 0 else i - SomeIpGuideLine.BEND_FROM_INDEX
                    val expected = heading + sign * SomeIpGuideLine.BEND_DEG_PER_STEP * bendSteps
                    val actual = bearingDegrees(pts[i - 1][1], pts[i - 1][0], pts[i][1], pts[i][0])
                    assertEquals(
                        "segment $i bearing @lat=$lat code=$code",
                        0.0, angleDelta(expected, actual), 0.25,
                    )
                }
            }
        }
    }

    /** Both families, both directions, and the code→direction map preserved. */
    @Test
    fun bendDirectionPerManeuverFamily() {
        for (code in listOf(1, 3, 4, 7)) assertEquals("code $code must bend LEFT", -1.0, SomeIpGuideLine.turnSign(code), 0.0)
        for (code in listOf(2, 5, 6, 8)) assertEquals("code $code must bend RIGHT", 1.0, SomeIpGuideLine.turnSign(code), 0.0)
        for (code in listOf(0, 9, 10, 11, 48, 99)) assertEquals("code $code must be STRAIGHT", 0.0, SomeIpGuideLine.turnSign(code), 0.0)

        for (lat in LATITUDES) {
            val fix = NavFix(lat, 55.2708, 0.0) // heading north
            val left = SomeIpGuideLine.points(fix, LEFT_CODE)
            val right = SomeIpGuideLine.points(fix, RIGHT_CODE)
            val straight = SomeIpGuideLine.points(fix, STRAIGHT_CODE)
            assertTrue("left must end west of the anchor @lat=$lat", left.last()[0] < fix.lon)
            assertTrue("right must end east of the anchor @lat=$lat", right.last()[0] > fix.lon)
            assertTrue("straight must not drift @lat=$lat", abs(straight.last()[0] - fix.lon) < 1e-9)
            // ...and the bend is suppressed for the first 6 points in every family.
            for (i in 0..SomeIpGuideLine.BEND_FROM_INDEX) {
                assertEquals("point $i must be un-bent (left) @lat=$lat", fix.lon, left[i][0], 1e-9)
                assertEquals("point $i must be un-bent (right) @lat=$lat", fix.lon, right[i][0], 1e-9)
            }
        }
    }

    /**
     * The bend is relative to the CAR, not to north — the property the old stub
     * could not have. Driving east, a left turn goes north and a right turn goes
     * south; under the old (always-northbound) model both would have moved in
     * longitude only.
     */
    @Test
    fun bendIsRelativeToHeadingNotToNorth() {
        val fix = NavFix(24.4539, 55.2708, 90.0) // driving due east
        val left = SomeIpGuideLine.points(fix, LEFT_CODE).last()
        val right = SomeIpGuideLine.points(fix, RIGHT_CODE).last()
        assertTrue("driving east, a LEFT turn must end north of the anchor", left[1] > fix.lat)
        assertTrue("driving east, a RIGHT turn must end south of the anchor", right[1] < fix.lat)
    }

    // =====================================================================
    // 5. fallback: byte-identical to the shipped stub
    // =====================================================================

    /**
     * NO REGRESSION. A car with no fix or no location permission must emit the
     * exact bytes we ship today. These literals are the frozen pre-TASK-005
     * output (`Double.toString` noise and all — note `39.905800000000006`, which
     * is the tell that this is a real capture and not a re-derivation).
     */
    @Test
    fun nullPositionIsByteIdenticalToTheLegacyStub() {
        assertEquals(FROZEN_STRAIGHT, SomeIpGuideLine.build(STRAIGHT_CODE, null, null, null))
        assertEquals(FROZEN_LEFT, SomeIpGuideLine.build(LEFT_CODE, null, null, null))
        assertEquals(FROZEN_RIGHT, SomeIpGuideLine.build(RIGHT_CODE, null, null, null))

        // ...and across the whole maneuver range, the fallback branch IS the stub.
        for (code in 0..49) {
            assertEquals(
                "code $code fallback diverged from the legacy stub",
                SomeIpGuideLine.buildStub(code),
                SomeIpGuideLine.build(code, null, null, null),
            )
        }
        // A heading alone is not a position.
        assertEquals(FROZEN_STRAIGHT, SomeIpGuideLine.build(STRAIGHT_CODE, null, null, 90.0))
    }

    /** Half a fix is no fix: never emit a coordinate we half-invented. */
    @Test
    fun partialOrImplausibleFixFallsBackToTheStub() {
        val stub = SomeIpGuideLine.buildStub(STRAIGHT_CODE)
        assertEquals("lat only", stub, SomeIpGuideLine.build(STRAIGHT_CODE, 24.45, null, 0.0))
        assertEquals("lon only", stub, SomeIpGuideLine.build(STRAIGHT_CODE, null, 55.27, 0.0))
        assertEquals("null island", stub, SomeIpGuideLine.build(STRAIGHT_CODE, 0.0, 0.0, 0.0))
        assertEquals("lat out of range", stub, SomeIpGuideLine.build(STRAIGHT_CODE, 91.0, 55.27, 0.0))
        assertEquals("lon out of range", stub, SomeIpGuideLine.build(STRAIGHT_CODE, 24.45, 181.0, 0.0))
        assertEquals("NaN lat", stub, SomeIpGuideLine.build(STRAIGHT_CODE, Double.NaN, 55.27, 0.0))
        assertEquals("Inf lon", stub, SomeIpGuideLine.build(STRAIGHT_CODE, 24.45, Double.POSITIVE_INFINITY, 0.0))

        // The shared plausibility gate itself (one decision, two consumers).
        assertNull(NavFix.of(null, 55.27))
        assertNull(NavFix.of(0.0, 0.0))
        assertEquals(NavFix(24.45, 55.27, 90.0), NavFix.of(24.45, 55.27, 90.0))
    }

    /** A real fix must NOT produce the stub — the whole point of the task. */
    @Test
    fun realPositionLeavesBeijingBehind() {
        val dubai = SomeIpGuideLine.build(STRAIGHT_CODE, 25.2048, 55.2708, 0.0)
        assertNotEquals(FROZEN_STRAIGHT, dubai)
        assertTrue("Beijing anchor still present: $dubai", !dubai.contains("116.4074"))
        assertTrue("Beijing anchor still present: $dubai", !dubai.contains("39.9042"))
        assertTrue("car's own position must be point 0", dubai.startsWith("[[55.270800,25.204800,0]"))
        assertEquals(SomeIpGuideLine.POINTS, parse(dubai).size)
    }

    // =====================================================================
    // 6. hostile inputs
    // =====================================================================

    /** Near the pole cos(lat)→0; the scaling latitude is clamped so longitudes
     *  stay finite and in range instead of flying off to ±inf. */
    @Test
    fun polarFixStaysFinite() {
        for (lat in listOf(89.999, -89.999, 90.0, -90.0)) {
            val out = SomeIpGuideLine.points(NavFix(lat, 55.2708, 90.0), STRAIGHT_CODE)
            assertTrue(
                "polar fix produced non-finite/out-of-range coords @lat=$lat: " +
                    out.joinToString { "${it[0]},${it[1]}" },
                out.all { it[0].isFinite() && it[1].isFinite() && abs(it[0]) < 360.0 },
            )
        }
    }

    /** Locale must not leak into the JSON (a comma decimal separator would turn
     *  each point into four components and silently break the cluster parse). */
    @Test
    fun outputUsesDotDecimalSeparatorRegardlessOfDefaultLocale() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY) // decimal comma
            val s = SomeIpGuideLine.build(STRAIGHT_CODE, 25.2048, 55.2708, 0.0)
            assertEquals(SomeIpGuideLine.POINTS, parse(s).size)
            assertTrue("locale decimal comma leaked into the polyline: $s", s.startsWith("[[55.270800,"))
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }
}
