package com.i99dev.ilink.nav.logic

/**
 * Byte-exact port of the reference's `mi0` bitset + `ym0.b/.d` perceptual-hash matcher
 * (verified). Classifies a maneuver-arrow bitmap (Waze) into the
 * registry icon name by 15×15 = 225-bit occupancy hash + Hamming distance ≤18.
 * Pure — no Android — so it's host-testable and produces hashes byte-identical
 * to the reference's (required to match the embedded [WazeArrowRegistry]).
 */
class Mi0(val bits: Int) {
    val words = LongArray((bits + 63) / 64)

    /** MSB-first within each 64-bit word (matches `mi0.a`). */
    fun set(i: Int) {
        words[i / 64] = words[i / 64] or (1L shl (63 - (i % 64)))
    }

    companion object {
        fun fromWords(w: LongArray, bits: Int = 225): Mi0 {
            val m = Mi0(bits)
            System.arraycopy(w, 0, m.words, 0, minOf(w.size, m.words.size))
            return m
        }

        fun fromBitString(s: String): Mi0 {
            val m = Mi0(s.length)
            for (i in s.indices) if (s[i] == '1') m.set(i)
            return m
        }
    }
}

object PerceptualHash {

    const val HAMMING_ACCEPT = 18
    const val CONTRAST_MIN = 30
    const val GRID = 15
    const val BITS = GRID * GRID // 225

    fun hamming(a: Mi0, b: Mi0): Int {
        require(a.bits == b.bits) { "signature lengths differ" }
        var d = 0
        for (i in a.words.indices) d += java.lang.Long.bitCount(a.words[i] xor b.words[i])
        return d
    }

    /** Nearest registry entry within [HAMMING_ACCEPT], or null. Exact match wins. */
    fun match(query: Mi0, registry: List<Pair<Mi0, String>>): String? {
        var best: String? = null
        var bestD = Int.MAX_VALUE
        for ((key, name) in registry) {
            if (key.bits != query.bits) continue
            val d = hamming(query, key)
            if (d == 0) return name
            if (d <= HAMMING_ACCEPT && d < bestD) {
                best = name; bestD = d
            }
        }
        return best
    }

    /**
     * Byte-exact `ym0.b`: ARGB pixels → 225-bit occupancy hash, or null when the
     * contrast gate (range < 30) fails. [bias] = the reference's 0.8f for Waze arrows.
     */
    fun buildHash(argb: IntArray, w: Int, h: Int, bias: Float, invertParam: Boolean): Mi0? {
        if (w <= 0 || h <= 0) return null
        val n = w * h
        val hasAlpha = !(argb.isEmpty() || ((argb[0] ushr 24) and 255) >= 255)

        val gray = IntArray(n)
        val alpha = if (hasAlpha) IntArray(n) else IntArray(0)
        var sumGray = 0L
        var opaqueCount = 0
        for (i in 0 until n) {
            val p = argb[i]
            val g = (((p ushr 16) and 255) + ((p ushr 8) and 255) + (p and 255)) / 3
            gray[i] = g
            if (hasAlpha) {
                val al = (p ushr 24) and 255
                alpha[i] = al
                if (al > 0) { opaqueCount++; sumGray += g }
            }
        }

        val hist = IntArray(256)
        val inv: Boolean = if (hasAlpha) {
            if (opaqueCount in 1 until n && sumGray.toFloat() / opaqueCount.toFloat() >= 128.0f) {
                false
            } else {
                invertParam && medianComposite47(gray, alpha, n, hist) >= 128
            }
        } else {
            invertParam && median(gray, n, hist) >= 128
        }

        val comp: IntArray
        var mn = 255
        var mx = 0
        if (!hasAlpha) {
            comp = gray
            for (i in 0 until n) { val g = comp[i]; if (g > mx) mx = g; if (g < mn) mn = g }
        } else {
            comp = IntArray(n)
            val bg = if (inv) 255 else 47
            for (i in 0 until n) {
                val al = alpha[i]
                val c = ((255 - al) * bg + gray[i] * al) / 255
                comp[i] = c; if (c > mx) mx = c; if (c < mn) mn = c
            }
        }

        val range = mx - mn
        if (range < CONTRAST_MIN) return null

        val threshold = if (inv) mn + ((1.0f - bias) * range).toInt() else mn + (range * bias).toInt()

        val sig = Mi0(BITS)
        var bit = 0
        for (gy in 0 until GRID) {
            val y0 = gy * h / GRID
            var y1 = (gy + 1) * h / GRID; if (y1 > h) y1 = h
            for (gx in 0 until GRID) {
                val x0 = gx * w / GRID
                var x1 = (gx + 1) * w / GRID; if (x1 > w) x1 = w
                var cnt = 0
                for (y in y0 until y1) {
                    val base = y * w
                    for (x in x0 until x1) {
                        val v = comp[base + x]
                        if (if (!inv) v >= threshold else v < threshold) cnt++
                    }
                }
                val area = (y1 - y0) * (x1 - x0)
                if (cnt > (area.toFloat() * 0.5f).toInt()) sig.set(bit)
                bit++
            }
        }
        return sig
    }

    private fun median(v: IntArray, n: Int, hist: IntArray): Int {
        java.util.Arrays.fill(hist, 0)
        for (k in 0 until n) {
            var x = v[k]; if (x < 0) x = 0 else if (x > 255) x = 255; hist[x]++
        }
        val half = n / 2 + 1
        var acc = 0
        for (idx in 0 until 256) { acc += hist[idx]; if (acc >= half) return idx }
        return 0
    }

    private fun medianComposite47(gray: IntArray, alpha: IntArray, n: Int, hist: IntArray): Int {
        val tmp = IntArray(n)
        for (i in 0 until n) {
            val al = alpha[i]
            tmp[i] = ((255 - al) * 47 + gray[i] * al) / 255
        }
        return median(tmp, n, hist)
    }
}
