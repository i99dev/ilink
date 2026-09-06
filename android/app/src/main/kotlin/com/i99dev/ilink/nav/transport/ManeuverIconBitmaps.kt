package com.i99dev.ilink.nav.transport

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import com.i99dev.ilink.nav.logic.ManeuverCatalog
import com.i99dev.ilink.nav.logic.ManeuverGlyph
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Renders the 128×128 ARGB maneuver-icon PNG for the SOME/IP payload (field 8),
 * **verbatim** from the reference's `SomeIpHudStrategy.drawManeuverIcon`:
 * paint `0xFF00E5FF`, 12 px round STROKE (FILL for the destination pin),
 * per-glyph vector path.
 *
 * The 49 codes collapse to 9 distinct shapes ([ManeuverGlyph]), so each glyph
 * is rendered+PNG-encoded ONCE and cached — the push hot path never re-encodes
 * (perf rule from the plan review). An invalid code yields empty bytes so the
 * codec omits the icon (safety: never draw a guessed maneuver).
 */
object ManeuverIconBitmaps {

    private const val PAINT_COLOR = 0xFF00E5FF.toInt()
    private val cache = ConcurrentHashMap<ManeuverGlyph, ByteArray>()

    /** PNG for a maneuver code, or empty bytes when the code is not a maneuver. */
    fun pngFor(maneuverCode: Int): ByteArray {
        if (!ManeuverCatalog.isValid(maneuverCode)) return EMPTY
        return cache.getOrPut(ManeuverCatalog.glyph(maneuverCode)) { render(ManeuverCatalog.glyph(maneuverCode)) }
    }

    private fun render(glyph: ManeuverGlyph): ByteArray {
        val bmp = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint().apply {
            color = PAINT_COLOR
            style = Paint.Style.STROKE
            strokeWidth = 12f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            isAntiAlias = true
        }
        val path = Path()
        when (glyph) {
            ManeuverGlyph.PIN -> {
                paint.style = Paint.Style.FILL
                canvas.drawCircle(64f, 48f, 24f, paint)
                path.moveTo(40f, 48f); path.lineTo(64f, 96f); path.lineTo(88f, 48f)
            }
            ManeuverGlyph.LEFT -> {
                path.moveTo(96f, 96f); path.lineTo(96f, 64f); path.cubicTo(96f, 48f, 80f, 32f, 64f, 32f); path.lineTo(32f, 32f)
                path.moveTo(48f, 16f); path.lineTo(32f, 32f); path.lineTo(48f, 48f)
            }
            ManeuverGlyph.RIGHT -> {
                path.moveTo(32f, 96f); path.lineTo(32f, 64f); path.cubicTo(32f, 48f, 48f, 32f, 64f, 32f); path.lineTo(96f, 32f)
                path.moveTo(80f, 16f); path.lineTo(96f, 32f); path.lineTo(80f, 48f)
            }
            ManeuverGlyph.SLIGHT_LEFT -> {
                path.moveTo(80f, 96f); path.lineTo(80f, 64f); path.lineTo(48f, 32f)
                path.moveTo(64f, 24f); path.lineTo(48f, 32f); path.lineTo(48f, 48f)
            }
            ManeuverGlyph.SLIGHT_RIGHT -> {
                path.moveTo(48f, 96f); path.lineTo(48f, 64f); path.lineTo(80f, 32f)
                path.moveTo(64f, 24f); path.lineTo(80f, 32f); path.lineTo(80f, 48f)
            }
            ManeuverGlyph.UTURN_LEFT -> {
                path.moveTo(80f, 96f); path.lineTo(80f, 48f); path.cubicTo(80f, 24f, 48f, 24f, 48f, 48f); path.lineTo(48f, 96f)
                path.moveTo(32f, 80f); path.lineTo(48f, 96f); path.lineTo(64f, 80f)
            }
            ManeuverGlyph.UTURN_RIGHT -> {
                path.moveTo(48f, 96f); path.lineTo(48f, 48f); path.cubicTo(48f, 24f, 80f, 24f, 80f, 48f); path.lineTo(80f, 96f)
                path.moveTo(64f, 80f); path.lineTo(80f, 96f); path.lineTo(96f, 80f)
            }
            ManeuverGlyph.STRAIGHT -> {
                path.moveTo(64f, 96f); path.lineTo(64f, 32f)
                path.moveTo(48f, 48f); path.lineTo(64f, 32f); path.lineTo(80f, 48f)
            }
            ManeuverGlyph.DOTTED_STRAIGHT -> {
                // Depart: the straight up-arrow with a DASHED shaft, so the route
                // start reads distinctly from a mid-route "continue straight".
                paint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(14f, 10f), 0f)
                path.moveTo(64f, 96f); path.lineTo(64f, 32f)
                path.moveTo(48f, 48f); path.lineTo(64f, 32f); path.lineTo(80f, 48f)
            }
            ManeuverGlyph.ROUNDABOUT -> {
                // The roundabout island + an entry stub from the bottom and an exit
                // arrow out the top — reads as "go around, take the exit" (generic;
                // the exact exit angle isn't encoded into the 9-glyph set).
                canvas.drawCircle(64f, 62f, 18f, paint)
                path.moveTo(64f, 112f); path.lineTo(64f, 80f) // entry from the bottom
                path.moveTo(64f, 44f); path.lineTo(64f, 12f) // exit up
                path.moveTo(50f, 26f); path.lineTo(64f, 12f); path.lineTo(78f, 26f) // arrowhead
            }
        }
        canvas.drawPath(path, paint)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return out.toByteArray()
    }

    private val EMPTY = ByteArray(0)
}
