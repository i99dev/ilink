package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavFix
import java.util.Locale
import kotlin.math.cos
import kotlin.math.sin

/**
 * Builds the SOME/IP field-30 "guideLine" string — a 10-point poly-line ahead of
 * the car, `[[lon,lat,0],…]`.
 *
 * Two branches, one entry point ([build]):
 *
 *  - **Real position** (a plausible [NavFix] is available): the line is projected
 *    from the car's ACTUAL coordinates, marching [STEP_METERS] per point along the
 *    car's ACTUAL [NavFix.heading], bending [BEND_DEG_PER_STEP] per step after
 *    point [BEND_FROM_INDEX] — left for maneuver codes {1,3,4,7}, right for
 *    {2,5,6,8}, straight otherwise.
 *  - **No position** (no fix / no location permission / implausible fix): falls
 *    back to [buildStub], which is the pre-TASK-005 reference algorithm kept
 *    **verbatim** so the wire is byte-identical to what we shipped before. That
 *    byte-identity is golden-tested — do not "tidy" [buildStub].
 *
 * The projection is local-tangent (equirectangular). The load-bearing part is the
 * **longitude scaling**: a degree of longitude is only as long as a degree of
 * latitude at the equator, so east/west offsets divide by
 * `cos(lat) * `[METERS_PER_DEG_LAT]. The old stub ignored this entirely (it added
 * raw degrees to both axes), which is why its "line" was the wrong shape anywhere
 * off the equator — and it was anchored in Beijing regardless of where the car was.
 *
 * Pure + host-testable: no Android imports, and the maths is exposed through
 * [points] so tests can assert real distances instead of comparing strings.
 */
object SomeIpGuideLine {

    // ---- projection constants ----

    /** Points emitted, including the car's own position at index 0. */
    const val POINTS = 10

    /** Ground distance between consecutive points. */
    const val STEP_METERS = 22.0

    /** Heading change applied per step once the bend starts. */
    const val BEND_DEG_PER_STEP = 15.0

    /** Points 0..[BEND_FROM_INDEX] are straight; the bend grows after that. */
    const val BEND_FROM_INDEX = 5

    /** Metres per degree of latitude (spherical-earth approximation). */
    const val METERS_PER_DEG_LAT = 111_000.0

    /** Latitude used for the cos() scaling is clamped here so a polar/garbage fix
     *  cannot divide by ~0 and fling the longitudes to infinity. */
    private const val MAX_SCALING_LAT = 85.0

    /** ~0.11 m of resolution — plenty for a 200 m poly-line, and it keeps the
     *  string short instead of emitting `Double.toString`'s 17-digit noise. */
    private const val COORD_FORMAT = "%.6f"

    // ---- legacy stub constants (fallback branch — frozen) ----

    private const val LAT0 = 39.9042
    private const val LON0 = 116.4074
    private const val STEP = 0.0002

    /**
     * THE entry point. [lat]/[lon]/[heading] come straight off the
     * [com.i99dev.ilink.nav.domain.NavGuidance] frame (stamped once at the
     * ingest boundary); any of them may be null.
     *
     * A null/implausible position is NOT an error — it is the documented fallback,
     * and it reproduces the previous behaviour byte-for-byte.
     */
    fun build(maneuverCode: Int, lat: Double?, lon: Double?, heading: Double?): String {
        val fix = NavFix.of(lat, lon, heading) ?: return buildStub(maneuverCode)
        val sb = StringBuilder("[")
        val pts = points(fix, maneuverCode)
        for (i in pts.indices) {
            if (i > 0) sb.append(",")
            sb.append("[").append(fmt(pts[i][0])).append(",").append(fmt(pts[i][1])).append(",0]")
        }
        return sb.append("]").toString()
    }

    /**
     * The maths, exposed. Returns [POINTS] `[lon, lat]` pairs, index 0 being the
     * car itself. Consecutive points are [STEP_METERS] apart on the ground at ANY
     * latitude — that invariant is what the host tests assert.
     */
    fun points(fix: NavFix, maneuverCode: Int): List<DoubleArray> {
        // No bearing (stationary car, network fix) → head north, which is exactly
        // what the old stub did. Never let a NaN/Inf bearing into the trig.
        val heading0 = fix.heading?.takeIf { it.isFinite() } ?: 0.0
        val turn = turnSign(maneuverCode)

        // Scale longitude by the local parallel's length. Clamped so |lat| ~ 90
        // cannot collapse the divisor.
        val scalingLat = fix.lat.coerceIn(-MAX_SCALING_LAT, MAX_SCALING_LAT)
        val metersPerDegLon = METERS_PER_DEG_LAT * cos(Math.toRadians(scalingLat))

        val out = ArrayList<DoubleArray>(POINTS)
        var lat = fix.lat
        var lon = fix.lon
        out.add(doubleArrayOf(lon, lat))
        for (i in 1 until POINTS) {
            // Segment i runs from point i-1 to point i. Segments up to
            // BEND_FROM_INDEX keep the car's heading; after that the bend grows
            // one BEND_DEG_PER_STEP per segment.
            val bendSteps = if (i <= BEND_FROM_INDEX) 0 else i - BEND_FROM_INDEX
            val bearing = Math.toRadians(heading0 + turn * BEND_DEG_PER_STEP * bendSteps)
            lat += (STEP_METERS * cos(bearing)) / METERS_PER_DEG_LAT
            lon += (STEP_METERS * sin(bearing)) / metersPerDegLon
            out.add(doubleArrayOf(lon, lat))
        }
        return out
    }

    /** −1 = bend left, +1 = bend right, 0 = straight. The code families are the
     *  reference's and are preserved exactly across the rewrite. */
    fun turnSign(maneuverCode: Int): Double = when (maneuverCode) {
        1, 3, 4, 7 -> -1.0
        2, 5, 6, 8 -> 1.0
        else -> 0.0
    }

    /**
     * The pre-TASK-005 algorithm, **verbatim** — a northbound line from the baked
     * Beijing anchor with the bend expressed as raw degrees of longitude. Wrong in
     * every way that matters, and deliberately kept: it is the no-position
     * fallback, and its output is pinned byte-for-byte by
     * `NavGuideLineTest.nullPositionIsByteIdenticalToTheLegacyStub`.
     *
     * Java/Kotlin `Double.toString` agree, so these bytes match what shipped.
     */
    fun buildStub(maneuverCode: Int): String {
        val sb = StringBuilder("[")
        for (i in 0 until 10) {
            val lat = i * STEP + LAT0
            val off = if (i <= 5) 0.0 else (i - 5) * STEP
            val lon = when (maneuverCode) {
                1, 3, 4, 7 -> LON0 - off
                2, 5, 6, 8 -> LON0 + off
                else -> LON0
            }
            sb.append("[").append(lon).append(",").append(lat).append(",0]")
            if (i < 9) sb.append(",")
        }
        return sb.append("]").toString()
    }

    /** Locale-pinned: a comma decimal separator would corrupt the JSON array. */
    private fun fmt(v: Double): String = String.format(Locale.US, COORD_FORMAT, v)
}
