package com.i99dev.ilink.nav.ingest

import java.nio.ByteBuffer

/**
 * Pure pixel-crop helper for the Waze arrow capture — extracted from the capture
 * service so it's host-testable (no Android dependency).
 *
 * The capture mirrors the FULL display into an ImageReader sized at the real
 * display, so a11y screen coordinates map 1:1 to buffer coordinates. We still
 * validate every crop against the buffer and **REJECT** (skip the frame) when it's
 * out of range — matching the reference's `isValidBounds`. We do NOT clamp: a
 * clamped/partial crop is a different-sized region that hashes to garbage matching
 * no signature, whereas rejecting waits for a valid frame.
 */
object ArrowCrop {

    /** True only when the crop is positive-sized and fully inside the buffer. */
    fun isValid(left: Int, top: Int, w: Int, h: Int, bufW: Int, bufH: Int): Boolean =
        w > 0 && h > 0 &&
            left >= 0 && top >= 0 &&
            left + w <= bufW && top + h <= bufH

    /**
     * Pack an RGBA_8888 [buf] sub-region (honouring [rowStride] padding +
     * [pixelStride]) into ARGB ints (`A<<24 | R<<16 | G<<8 | B`). The caller must
     * guarantee [isValid] for the same rect, so reads never run past the buffer.
     */
    fun extract(
        buf: ByteBuffer,
        rowStride: Int,
        pixelStride: Int,
        left: Int,
        top: Int,
        w: Int,
        h: Int,
    ): IntArray {
        val argb = IntArray(w * h)
        var idx = 0
        for (y in 0 until h) {
            var p = (top + y) * rowStride + left * pixelStride
            for (x in 0 until w) {
                val r = buf.get(p).toInt() and 0xFF
                val g = buf.get(p + 1).toInt() and 0xFF
                val b = buf.get(p + 2).toInt() and 0xFF
                val a = buf.get(p + 3).toInt() and 0xFF
                argb[idx++] = (a shl 24) or (r shl 16) or (g shl 8) or b
                p += pixelStride
            }
        }
        return argb
    }
}
