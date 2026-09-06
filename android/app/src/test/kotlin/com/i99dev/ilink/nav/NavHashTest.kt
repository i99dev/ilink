package com.i99dev.ilink.nav

import com.i99dev.ilink.nav.logic.Mi0
import com.i99dev.ilink.nav.logic.PerceptualHash
import com.i99dev.ilink.nav.logic.WazeArrowRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Host-JVM coverage for the byte-exact perceptual-hash matcher + Waze registry. */
class NavHashTest {

    @Test
    fun registryEntriesSelfMatchWithCode() {
        val entries = WazeArrowRegistry.entries
        assertEquals(32, entries.size)
        for (e in entries) {
            assertEquals("self-hamming must be 0", 0, PerceptualHash.hamming(e.hash, e.hash))
            assertTrue("code in 1..49", e.code in 1..49)
            // nearest entry to its own hash is itself (d == 0)
            val nearest = entries.minByOrNull { PerceptualHash.hamming(e.hash, it.hash) }!!
            assertEquals(0, PerceptualHash.hamming(e.hash, nearest.hash))
        }
    }

    @Test
    fun matchFindsNearestWithinThreshold() {
        val pairs = WazeArrowRegistry.entries.map { it.hash to it.name }
        val target = WazeArrowRegistry.entries.first { it.name == "direction_left" }
        // exact
        assertEquals("direction_left", PerceptualHash.match(target.hash, pairs))
        // perturb 10 bits (≤18) → still matches; perturb 25 bits → drops out (if it
        // doesn't collide with another entry) — assert the exact path at least.
        val near = Mi0.fromWords(target.hash.words.clone())
        near.words[0] = near.words[0] xor 0x3FFL // flip 10 low bits of word 0
        val m = PerceptualHash.match(near, pairs)
        assertNotNull(m) // within 18 of *some* entry (itself)
    }

    @Test
    fun buildHashContrastGateAndDeterminism() {
        val w = 30; val h = 30
        // flat opaque image → range 0 → null (contrast gate)
        val flat = IntArray(w * h) { 0xFF808080.toInt() }
        assertNull(PerceptualHash.buildHash(flat, w, h, 0.8f, true))

        // left half black, right half white (opaque) → high contrast → non-null
        val split = IntArray(w * h) { i -> if (i % w < w / 2) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
        val a = PerceptualHash.buildHash(split, w, h, 0.8f, true)
        val b = PerceptualHash.buildHash(split, w, h, 0.8f, true)
        assertNotNull(a)
        assertEquals(PerceptualHash.BITS, a!!.bits)
        // deterministic
        assertTrue(a.words.contentEquals(b!!.words))
        // some bits set (the bright half)
        assertTrue(a.words.any { it != 0L })
    }

    @Test
    fun classifyReturnsNullOnNoContrast() {
        val flat = IntArray(20 * 20) { 0xFF404040.toInt() }
        assertNull(WazeArrowRegistry.classify(flat, 20, 20))
    }
}
