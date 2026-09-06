package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavFix
import com.i99dev.ilink.nav.domain.NavLane
import java.io.ByteArrayOutputStream
import java.util.Locale

/**
 * Encodes the SOME/IP "RoadInfo" payload that rides `transact(6)` to
 * `ts.car.someip.sdk.ISomeIpServerInterface` — **byte-for-byte** as the reference
 * 2.3.1's `SomeIpHudStrategy.buildRoadInfo`. Pure: no
 * Android imports, so the exact wire is host-JVM unit-testable.
 *
 * Ground-truth field map (inner message, then wrapped in field 1):
 * ```
 *   2  varint  counter (0..255 rolling)
 *   8  bytes   128x128 ARGB PNG maneuver icon   [omitted if empty]
 *   9  varint  distanceMeters
 *   10 string  roadName
 *   16 varint  2 (const)
 *   19 double  lon (live position, else STUB_LON)
 *   20 double  lat (live position, else STUB_LAT)
 *   26 string  eta                              [omitted if empty]
 *   28 varint  maneuverCode
 *   30 string  guideLine (polyline JSON)
 *   31 string  "lon,lat,0" (live position, else STUB_POS)
 *   5  varint  laneCount                        [only if lane present]
 *   29 string  "code,active|code,active|..."    [only if lane present]
 * envelope: field 1 (tag 0x0A) length-delimited wrapping the inner message
 * ```
 * **TASK-005:** fields 19/20/31 used to be a hardcoded Beijing coordinate on every
 * car, everywhere. They now carry the real fix when we have one. The stub survives
 * ONLY as the no-fix / no-permission fallback, and that fallback is byte-identical
 * to what shipped before (golden-tested) — a car without location permission emits
 * exactly the previous wire.
 */
object SomeIpRoadInfoCodec {
    const val STUB_LON: Double = 116.4074
    const val STUB_LAT: Double = 39.9042
    const val STUB_POS: String = "116.4074,39.9042,0"

    /** Field-31 position string for a real fix. Locale-pinned (a comma decimal
     *  separator would split the field into extra components). */
    fun positionString(lon: Double, lat: Double): String =
        String.format(Locale.US, "%.6f,%.6f,0", lon, lat)

    /**
     * @param counter rolling 0..255 (caller increments `(c+1) and 0xFF`)
     * @param maneuverCode field 28 (the maneuver; also keys [guideLine]/icon)
     * @param distanceMeters field 9
     * @param roadName field 10
     * @param eta field 26 (omitted when empty)
     * @param iconPng field 8 (omitted when empty) — caller supplies the cached PNG
     * @param guideLine field 30 — synthetic polyline (see [SomeIpGuideLine])
     * @param lane fields 5 + 29 (omitted when null/empty)
     * @param lat fields 20 + 31 — null (or implausible) falls back to the stub
     * @param lon fields 19 + 31 — null (or implausible) falls back to the stub
     */
    fun buildRoadInfo(
        counter: Int,
        maneuverCode: Int,
        distanceMeters: Int,
        roadName: String,
        eta: String,
        iconPng: ByteArray,
        guideLine: String,
        lane: NavLane?,
        lat: Double? = null,
        lon: Double? = null,
    ): ByteArray {
        // ONE plausibility decision, shared with SomeIpGuideLine via NavFix.of, so
        // fields 19/20/31 and the field-30 polyline can never disagree about
        // whether this frame has a real position.
        val fix = NavFix.of(lat, lon)
        val inner = ByteArrayOutputStream()
        writeVarintField(inner, 2, counter.toLong())
        if (iconPng.isNotEmpty()) writeBytesField(inner, 8, iconPng)
        writeVarintField(inner, 9, distanceMeters.toLong())
        writeStringField(inner, 10, roadName)
        writeVarintField(inner, 16, 2)
        writeDoubleField(inner, 19, fix?.lon ?: STUB_LON)
        writeDoubleField(inner, 20, fix?.lat ?: STUB_LAT)
        if (eta.isNotEmpty()) writeStringField(inner, 26, eta)
        writeVarintField(inner, 28, maneuverCode.toLong())
        writeStringField(inner, 30, guideLine)
        writeStringField(inner, 31, fix?.let { positionString(it.lon, it.lat) } ?: STUB_POS)
        if (lane != null && lane.laneCodes.isNotEmpty()) {
            writeVarintField(inner, 5, lane.laneCodes.size.toLong())
            val sb = StringBuilder()
            for (i in lane.laneCodes.indices) {
                val code = lane.laneCodes[i]
                // active flag present → emit the code again, else 0 (the reference verbatim)
                val active = if (i < lane.activeIndices.size && lane.activeIndices[i]) code else 0
                sb.append(code).append(',').append(active).append('|')
            }
            writeStringField(inner, 29, sb.toString())
        }
        val innerBytes = inner.toByteArray()

        val env = ByteArrayOutputStream()
        env.write(0x0A) // field 1, wire-type 2 (length-delimited)
        writeVarint(env, innerBytes.size.toLong())
        env.write(innerBytes)
        return env.toByteArray()
    }

    // --- protobuf encoders (exact, matching the reference) ---

    internal fun writeVarintField(out: ByteArrayOutputStream, field: Int, value: Long) {
        writeVarint(out, field.toLong() shl 3)              // tag, wire-type 0
        writeVarint(out, value)
    }

    internal fun writeBytesField(out: ByteArrayOutputStream, field: Int, bytes: ByteArray) {
        writeVarint(out, (field.toLong() shl 3) or 2)       // wire-type 2
        writeVarint(out, bytes.size.toLong())
        out.write(bytes)
    }

    internal fun writeStringField(out: ByteArrayOutputStream, field: Int, value: String) {
        writeVarint(out, (field.toLong() shl 3) or 2)
        val b = value.toByteArray(Charsets.UTF_8)
        writeVarint(out, b.size.toLong())
        out.write(b)
    }

    internal fun writeDoubleField(out: ByteArrayOutputStream, field: Int, value: Double) {
        writeVarint(out, (field.toLong() shl 3) or 1)       // wire-type 1 (64-bit)
        val bits = java.lang.Double.doubleToLongBits(value)
        for (i in 0 until 8) out.write(((bits shr (i * 8)) and 0xFF).toInt())  // little-endian
    }

    internal fun writeVarint(out: ByteArrayOutputStream, v: Long) {
        var value = v
        while (true) {
            val b = (value and 0x7F).toInt()
            value = value ushr 7
            if (value == 0L) {
                out.write(b)
                return
            }
            out.write(b or 0x80)
        }
    }
}
