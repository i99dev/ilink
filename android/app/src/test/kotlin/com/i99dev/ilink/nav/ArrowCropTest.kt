package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.ingest.ArrowCrop
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

/** Host coverage for the pure Waze-arrow crop math (the on-car capture calls this). */
class ArrowCropTest {

    @Test
    fun isValidAcceptsInBoundsRejectsOutOfBounds() {
        assertTrue(ArrowCrop.isValid(0, 0, 10, 10, 100, 100))
        assertTrue(ArrowCrop.isValid(90, 90, 10, 10, 100, 100)) // exactly fits
        assertFalse(ArrowCrop.isValid(-1, 0, 10, 10, 100, 100)) // left < 0
        assertFalse(ArrowCrop.isValid(0, -1, 10, 10, 100, 100)) // top < 0
        assertFalse(ArrowCrop.isValid(0, 0, 0, 10, 100, 100)) // width 0
        assertFalse(ArrowCrop.isValid(0, 0, 10, 0, 100, 100)) // height 0
        assertFalse(ArrowCrop.isValid(95, 0, 10, 10, 100, 100)) // left+w > bufW
        assertFalse(ArrowCrop.isValid(0, 95, 10, 10, 100, 100)) // top+h > bufH
    }

    @Test
    fun extractPacksRgbaToArgbHonouringRowStridePadding() {
        // 3x2 buffer, pixelStride=4, rowStride=16 (= 3*4 + 4 bytes of row padding).
        val w = 3; val h = 2; val pixelStride = 4; val rowStride = 16
        val buf = ByteBuffer.allocate(rowStride * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val p = y * rowStride + x * pixelStride
                buf.put(p, (x * 10).toByte()) // R
                buf.put(p + 1, (y * 20).toByte()) // G
                buf.put(p + 2, (x + y).toByte()) // B
                buf.put(p + 3, 0xFF.toByte()) // A
            }
        }
        val argb = ArrowCrop.extract(buf, rowStride, pixelStride, 0, 0, w, h)
        assertEquals(w * h, argb.size)
        // (0,0): R0 G0 B0 A255
        assertEquals((0xFF shl 24), argb[0])
        // (2,1): R20 G20 B3 A255 — proves rowStride padding didn't shift the read
        assertEquals((0xFF shl 24) or (20 shl 16) or (20 shl 8) or 3, argb[1 * w + 2])
    }

    @Test
    fun extractCropsSubRegionAtOffset() {
        // 4x3 buffer, rowStride=20 (= 4*4 + 4 padding). Crop 2x2 at (1,1).
        val w = 4; val h = 3; val pixelStride = 4; val rowStride = 20
        val buf = ByteBuffer.allocate(rowStride * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val p = y * rowStride + x * pixelStride
                buf.put(p, x.toByte()); buf.put(p + 1, y.toByte())
                buf.put(p + 2, 0); buf.put(p + 3, 0xFF.toByte())
            }
        }
        val argb = ArrowCrop.extract(buf, rowStride, pixelStride, 1, 1, 2, 2)
        assertEquals(4, argb.size)
        assertEquals((0xFF shl 24) or (1 shl 16) or (1 shl 8), argb[0]) // src (1,1)
        assertEquals((0xFF shl 24) or (2 shl 16) or (2 shl 8), argb[3]) // src (2,2)
    }
}
