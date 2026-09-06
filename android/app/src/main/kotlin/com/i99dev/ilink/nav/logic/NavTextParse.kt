package com.i99dev.ilink.nav.logic

/**
 * Parses distance + time *out* of nav-app text (notification title/subText,
 * a11y labels) into the canonical int fields. This is the universal,
 * app-agnostic ingestion primitive — combined with [ManeuverTextMap] it lets
 * the notification channel support *most* nav apps without per-app view-ids.
 *
 * Regexes mirror the reference's `w40`/`ym0` parsers: metric (+ mi),
 * NBSP-tolerant, decimal-comma normalised, km/RU-km x1000. All non-ASCII is
 * \u-escaped (regular strings, not raw) so the source stays ASCII-clean.
 * Pure + host-testable.
 */
object NavTextParse {

    private const val NBSP = " "
    private const val KM_RU = "км"          // km (Cyrillic)
    private const val M_RU = "м"                 // m  (Cyrillic)
    private const val M_CH = "米"            // m  (Chinese, 米)
    private const val CH_RU = "ч"                // ch (hour, Cyrillic)
    private const val MIN_RU = "мин"   // min (Cyrillic)
    private const val CYR = "а-яА-Я" // a-ya A-YA
    // Arabic units (literal UTF-8, as with the Cyrillic/Chinese units above).
    // Google Maps in an Arabic locale renders distance/ETA in Arabic-Indic
    // numerals + Arabic words, e.g. "٩٠ متر" ("90 m") — without these units (and
    // the digit folding in normalizeDigits below) the ASCII-digit regexes never
    // match, so the app is never detected.
    private const val M_AR = "متر" //                   metre (متر)
    private const val KM_AR = "كم" //                           km (كم)
    private const val KM_AR2 = "كيلومتر" // km (كيلومتر)
    private const val HOUR_AR = "ساعة" //           hour (ساعة)
    private const val HOUR_AR2 = "ساعات" //   hours (ساعات)
    private const val MIN_AR = "دقيقة" //    minute (دقيقة)
    private const val MIN_AR2 = "دقائق" //  minutes (دقائق)

    // (\d+[.,]?\d*) <sp/nbsp> (km|RUkm|ARkm|mi|ft|yd|m|RUm|CHm|ARm) not followed by
    // a Latin/Cyrillic letter. Multi-char/script units precede bare ones so the
    // alternation prefers the longer match (ft/yd/mi + ARkm/ARm before bare m). The
    // Arabic units are full words, so no Arabic sub-word guard is needed (and adding
    // one would wrongly reject a unit followed by Arabic punctuation, e.g. "متر،").
    private val DISTANCE = Regex(
        "(\\d+[.,]?\\d*)[\\s$NBSP]*($KM_AR2|km|$KM_RU|$KM_AR|mi|ft|yd|$M_AR|m|$M_RU|$M_CH)" +
            "(?![a-zA-Z$CYR])",
        RegexOption.IGNORE_CASE,
    )
    private val HOURS = Regex(
        "(\\d+)[\\s$NBSP]*(?:hrs|hr|hours|hour|$HOUR_AR2|$HOUR_AR|$CH_RU\\.|$CH_RU|h)" +
            "(?![a-zA-Z$CYR])",
        RegexOption.IGNORE_CASE,
    )
    // minutes: min/mins/RUmin/ARmin ONLY — never bare "m" (that's metres, not minutes)
    private val MINUTES = Regex(
        "(\\d+)[\\s$NBSP]*(?:mins|min|$MIN_AR2|$MIN_AR|$MIN_RU)(?![a-zA-Z$CYR])",
        RegexOption.IGNORE_CASE,
    )

    /** "750 m" -> 750, "1.5 km" -> 1500, "2,3 RUkm" -> 2300, "0.3 mi" -> 482,
     *  "500 ft" -> 152, "100 yd" -> 91, "500 CHm" -> 500. Bare metres (m/RUm/CHm)
     *  are integer-only (a glitchy "0.4 m" is rejected, not rounded to 0 m). */
    /** Fold Arabic-Indic (٠-٩) and Extended/Persian (۰-۹) digits to ASCII, plus the
     *  Arabic decimal/thousands marks. Arabic-locale nav apps (Google Maps etc.)
     *  render the distance/ETA in these, so without folding the ASCII-digit regexes
     *  never match → the app is never detected. Cheap no-op fast-path for the common
     *  all-ASCII case. */
    private fun normalizeDigits(s: String): String {
        var needs = false
        for (ch in s) {
            if (ch in '٠'..'٩' || ch in '۰'..'۹' || ch == '٫' || ch == '٬') {
                needs = true
                break
            }
        }
        if (!needs) return s
        val sb = StringBuilder(s.length)
        for (ch in s) {
            sb.append(
                when (ch) {
                    in '٠'..'٩' -> '0' + (ch - '٠')
                    in '۰'..'۹' -> '0' + (ch - '۰')
                    '٫' -> '.'
                    '٬' -> ','
                    else -> ch
                },
            )
        }
        return sb.toString()
    }

    fun distanceMeters(s: String?): Int? {
        if (s.isNullOrBlank()) return null
        val m = DISTANCE.find(normalizeDigits(s)) ?: return null
        val raw = m.groupValues[1]
        val n = raw.replace(',', '.').toDoubleOrNull() ?: return null
        val unit = m.groupValues[2].lowercase()
        // metres are integer-only; a decimal with a metre unit is not a real distance
        if ((unit == "m" || unit == M_RU || unit == M_CH || unit == M_AR) &&
            (raw.contains('.') || raw.contains(','))
        ) {
            return null
        }
        val meters = when (unit) {
            "km", KM_RU, KM_AR, KM_AR2 -> n * 1000.0
            "mi" -> n * 1609.34
            "ft" -> n * 0.3048
            "yd" -> n * 0.9144
            else -> n // m / RUm / CHm / ARm
        }
        return meters.toInt()
    }

    /** "45 min" -> 2700, "2 h 5 min" -> 7500. */
    fun timeSeconds(s: String?): Int? {
        if (s.isNullOrBlank()) return null
        val norm = normalizeDigits(s)
        val h = HOURS.find(norm)?.groupValues?.get(1)?.toIntOrNull() ?: 0
        val min = MINUTES.find(norm)?.groupValues?.get(1)?.toIntOrNull() ?: 0
        val total = h * 3600 + min * 60
        return if (total > 0) total else null
    }

    // Google Maps next-step phrases ("then turn right onto …") whose leading
    // maneuver verb we strip to leave the road name — ordered most-specific first
    // (the "onto" variants before their bare forms, "then …" before the no-"then"
    // forms). Verbatim ordering from the reference's GoogleMapsManager.PREFIX_REGEXES.
    private val NEXT_STEP_PREFIXES: List<Regex> = listOf(
        "then\\s+turn\\s+right\\s+onto\\s*", "then\\s+turn\\s+left\\s+onto\\s*",
        "then\\s+merge\\s+onto\\s*", "then\\s+take\\s+the\\s+ramp\\s+onto\\s*",
        "then\\s+keep\\s+right\\s+onto\\s*", "then\\s+keep\\s+left\\s+onto\\s*",
        "then\\s+take\\s+the\\s+exit\\s+onto\\s*", "then\\s+turn\\s+sharp\\s+right\\s+onto\\s*",
        "then\\s+turn\\s+sharp\\s+left\\s+onto\\s*", "then\\s+turn\\s+slight\\s+right\\s+onto\\s*",
        "then\\s+turn\\s+slight\\s+left\\s+onto\\s*", "then\\s+turn\\s+right\\s*",
        "then\\s+turn\\s+left\\s*", "then\\s+merge\\s*", "then\\s+keep\\s+right\\s*",
        "then\\s+keep\\s+left\\s*", "then\\s*", "turn\\s+right\\s+onto\\s*",
        "turn\\s+left\\s+onto\\s*", "merge\\s+onto\\s*", "take\\s+the\\s+ramp\\s+onto\\s*",
        "keep\\s+right\\s+onto\\s*", "keep\\s+left\\s+onto\\s*", "take\\s+the\\s+exit\\s+onto\\s*",
    ).map { Regex("^$it", RegexOption.IGNORE_CASE) }

    /** Strip the leading maneuver phrase from a Google Maps next-step string so only
     *  the secondary road remains ("then turn right onto Elm St" -> "Elm St"). First
     *  matching prefix wins; no match returns the trimmed input unchanged. */
    fun cleanNextStep(s: String?): String {
        val t = s?.trim().orEmpty()
        if (t.isEmpty()) return ""
        for (re in NEXT_STEP_PREFIXES) {
            if (re.containsMatchIn(t)) return re.replaceFirst(t, "").trim()
        }
        return t
    }
}
