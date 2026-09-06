package com.i99dev.ilink.nav.logic

import java.text.Normalizer

/**
 * Sanitizes road names for the cluster — verbatim from the reference's
 * `HudTextSanitizer`. Per-char: CJK ideographs pass through untouched; every
 * other char is transliterated to Latin-ASCII via ICU `"Any-Latin; Latin-ASCII"`,
 * falling back to NFD diacritic-stripping when ICU is unavailable (e.g. host
 * unit tests, or ICU init failure). Result is trimmed.
 *
 * The ICU path is Android-only; the [fallback] path is pure JDK and is what the
 * host tests exercise.
 */
object HudTextSanitizer {

    private val icu: android.icu.text.Transliterator? by lazy {
        runCatching { android.icu.text.Transliterator.getInstance("Any-Latin; Latin-ASCII") }.getOrNull()
    }

    /** CJK ranges the reference preserves (Unified, Ext-A, Compat Ideographs). */
    fun isCjk(c: Char): Boolean =
        c.code in 0x4E00..0x9FFF || c.code in 0x3400..0x4DBF || c.code in 0xF900..0xFDFF

    fun sanitize(s: String?): String {
        if (s.isNullOrBlank()) return ""
        val sb = StringBuilder()
        for (c in s) {
            if (isCjk(c)) {
                sb.append(c)
                continue
            }
            val one = c.toString()
            val t = icu
            sb.append(
                if (t == null) fallback(one)
                else runCatching { t.transliterate(one) }.getOrElse { fallback(one) },
            )
        }
        return sb.toString().trim()
    }

    /** Pure JDK fallback: NFD → strip combining marks → ñ/Ñ → n/N. */
    fun fallback(x: String): String =
        Normalizer.normalize(x, Normalizer.Form.NFD)
            .replace(Regex("\\p{InCombiningDiacriticalMarks}+"), "")
            .replace("ñ", "n")
            .replace("Ñ", "N")
}
