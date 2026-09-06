package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavLane

/**
 * Waze lane-guidance extraction — the pure (host-testable) core of the P2 scaffold,
 * ported from the reference's `WazeArrowCaptureService.segmentLaneGuidanceView` /
 * `processSegmentedLanes`.
 *
 * Waze draws the lane row (`:id/laneGuidanceView`) as a bitmap of side-by-side lane
 * glyphs. We crop that row's pixels (the a11y side gives the bounds — see
 * [com.i99dev.ilink.nav.ingest.WazeLaneBounds]), split it into per-lane bands by
 * column energy, classify each band's glyph, and emit a [NavLane]. The SOME/IP codec
 * already serializes [NavLane], so a populated lane lights up the cluster lane row
 * with no transport change.
 *
 * DEGRADE-SAFE: classification ([LaneClassifier]) is a stub until the lane-glyph
 * signature table is captured on-car, so [WazeLaneCapture.fromLaneRow] returns null
 * (no lanes pushed = exactly today's behaviour) until calibrated. Only that one
 * table changes after calibration; the segmentation + wire path stay.
 */
object LaneSegmenter {

    /** A detected lane band within the lane-row crop (row-local coordinates). */
    data class Band(
        val left: Int,
        val top: Int,
        val width: Int,
        val height: Int,
        val strength: Float,
    )

    /** Column-energy threshold for "this column contains glyph ink". Tunable on-car. */
    const val ENERGY_THRESHOLD = 40f

    /**
     * Segment an ARGB lane-row [argb] (size width*height) into per-lane bands. A
     * column's energy = mean brightness × opacity over its rows (lane glyphs are
     * bright + opaque on a transparent row background); contiguous high-energy
     * columns (bridging gaps ≤ 8dp) form a band, kept only at 15–120dp wide. [density]
     * is the display density (dp→px). Pure — no Android.
     */
    fun segment(argb: IntArray, width: Int, height: Int, density: Float): List<Band> {
        if (width <= 0 || height <= 0 || argb.size < width * height) return emptyList()

        val col = FloatArray(width)
        for (y in 0 until height) {
            val rowBase = y * width
            for (x in 0 until width) {
                val p = argb[rowBase + x]
                val a = (p ushr 24) and 0xFF
                val r = (p ushr 16) and 0xFF
                val g = (p ushr 8) and 0xFF
                val b = p and 0xFF
                col[x] += ((r + g + b) / 3f) * (a / 255f)
            }
        }
        val denom = (height / 2f).coerceAtLeast(1f)
        for (x in 0 until width) col[x] /= denom

        val minGap = (8 * density).toInt().coerceAtLeast(1)
        val minBand = (15 * density).toInt().coerceAtLeast(1)
        val maxBand = (120 * density).toInt().coerceAtLeast(minBand + 1)

        // Group contiguous high-energy columns, bridging gaps ≤ minGap.
        val ranges = ArrayList<IntArray>()
        var start = -1
        var end = -1
        for (x in 0 until width) {
            if (col[x] >= ENERGY_THRESHOLD) {
                if (start == -1) start = x
                end = x
            } else if (start != -1 && x - end > minGap) {
                ranges.add(intArrayOf(start, end))
                start = -1
                end = -1
            }
        }
        if (start != -1) ranges.add(intArrayOf(start, end))

        val bands = ArrayList<Band>(ranges.size)
        for (rng in ranges) {
            val w = rng[1] - rng[0] + 1
            if (w in minBand..maxBand) {
                var peak = 0f
                for (x in rng[0]..rng[1]) if (col[x] > peak) peak = col[x]
                bands.add(Band(rng[0], 0, w, height, peak))
            }
        }
        return bands
    }
}

/**
 * One lane band's glyph → BYD `LANE_ICON_*` code (0..25), or null when there's no
 * confident match.
 *
 * Uses the reference as the car-tested source of truth: a lane band is classified with the
 * SAME perceptual-hash registry the reference uses for the maneuver arrow ([WazeArrowRegistry],
 * a verbatim port of its `qm1`/`zm1.a`), then the matched maneuver (`TURN_ICON_*`) is
 * mapped to the cluster's `LANE_ICON_*` space via the reference's documented icon constants
 * (`HudController.LANE_ICON_*` / `TURN_ICON_*`). No match, or a maneuver with no lane
 * equivalent (e.g. a roundabout), → null (that band is dropped) — degrade-safe.
 *
 * The exact band-level mapping in the reference's `processSegmentedLanes` did not decompile
 * (method body skipped), so the [TURN_TO_LANE] table is derived from the icon
 * constants and is the one thing to confirm on-car; the registry + segmentation are
 * verbatim.
 */
object LaneClassifier {

    // BYD LANE_ICON_* (HudController), the codes sendLaneGuidanceInfo expects.
    private const val LANE_STRAIGHT = 0
    private const val LANE_LEFT = 1
    private const val LANE_RIGHT = 3
    private const val LANE_U_TURN_R_TO_L = 5
    private const val LANE_U_TURN_L_TO_R = 8

    /** TURN_ICON_* (registry output) → LANE_ICON_*. Only the directional maneuvers
     *  have a lane equivalent; everything else (roundabouts, etc.) → no lane. */
    private val TURN_TO_LANE: Map<Int, Int> = mapOf(
        1 to LANE_LEFT,            // TURN_ICON_LEFT
        2 to LANE_RIGHT,           // TURN_ICON_RIGHT
        3 to LANE_LEFT,            // SLIGHT_LEFT
        4 to LANE_LEFT,            // SLIGHT_LEFT_ALT
        5 to LANE_RIGHT,           // SLIGHT_RIGHT
        6 to LANE_RIGHT,           // SLIGHT_RIGHT_ALT
        7 to LANE_LEFT,            // SHARP_LEFT
        8 to LANE_RIGHT,           // SHARP_RIGHT
        9 to LANE_U_TURN_R_TO_L,   // U_TURN_LEFT
        10 to LANE_U_TURN_L_TO_R,  // U_TURN_RIGHT
        11 to LANE_STRAIGHT,       // STRAIGHT_SOLID
        12 to LANE_STRAIGHT,       // STRAIGHT_DOTTED
    )

    fun classifyBand(argb: IntArray, width: Int, height: Int): Int? {
        val turn = WazeArrowRegistry.classify(argb, width, height) ?: return null
        return TURN_TO_LANE[turn]
    }
}

/** Builds a [NavLane] from a cropped lane-guidance row. */
object WazeLaneCapture {

    /** Strongest-band fraction at/above which a lane is "recommended" (active). */
    private const val ACTIVE_FRACTION = 0.75f

    /**
     * Segment [argb] (the lane row, width*height) into bands, classify each, and
     * build a [NavLane]. Returns null when there are no bands OR no band classifies
     * (uncalibrated) — so we never push placeholder lanes that would render wrong
     * arrows. [density] is the display density.
     */
    fun fromLaneRow(argb: IntArray, width: Int, height: Int, density: Float): NavLane? {
        val bands = LaneSegmenter.segment(argb, width, height, density)
        if (bands.isEmpty()) return null
        val maxStrength = bands.maxOf { it.strength }.coerceAtLeast(1f)
        val codes = ArrayList<Int>(bands.size)
        val active = ArrayList<Boolean>(bands.size)
        var anyClassified = false
        for (band in bands) {
            val sub = cropBand(argb, width, band)
            val code = LaneClassifier.classifyBand(sub, band.width, band.height)
            if (code != null) anyClassified = true
            codes.add(code ?: 0)
            active.add(band.strength >= maxStrength * ACTIVE_FRACTION)
        }
        return if (anyClassified) NavLane(laneCodes = codes, activeIndices = active) else null
    }

    /** Copy a band's sub-region out of the row ARGB into its own tight buffer. */
    private fun cropBand(rowArgb: IntArray, rowWidth: Int, band: LaneSegmenter.Band): IntArray {
        val out = IntArray(band.width * band.height)
        var idx = 0
        for (y in 0 until band.height) {
            val base = (band.top + y) * rowWidth + band.left
            for (x in 0 until band.width) out[idx++] = rowArgb[base + x]
        }
        return out
    }
}
