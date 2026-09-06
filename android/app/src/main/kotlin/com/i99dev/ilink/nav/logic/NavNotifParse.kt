package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * The universal, app-agnostic notification parser — turns the standard
 * `Notification` extras (title / text / subText / bigText) of ANY ongoing nav
 * notification into a canonical [NavGuidance]. This is what lets the HUD
 * "support most maps" with no per-app view-ids: maneuver via [ManeuverTextMap],
 * distance/ETA via [NavTextParse], road via a small "onto/on/toward" heuristic.
 *
 * Field semantics shift per app (some put the street in title, some in text), so
 * the parser is deliberately position-tolerant: it scans every field. Precise
 * per-app data comes from the a11y sources; this is the broad baseline. Pure +
 * host-testable.
 */
object NavNotifParse {

    // " to " / " on to " removed: too generic — they orphan a "street" out of full
    // maneuver-status lines ("Head to Main St"). "onto"/"toward"/"on" stay.
    private val ROAD_SEPARATORS = listOf(" onto ", " on ", " toward ", " towards ")

    fun parse(
        title: String?,
        text: String?,
        subText: String?,
        bigText: String?,
        source: NavSourceId,
        /** Maneuver derived upstream from the notification (large-icon / title) —
         *  THE direction authority. When a valid 1..49 code, it overrides the
         *  local text classify; null falls back to classifying the instruction. */
        maneuverOverride: Int? = null,
    ): NavGuidance? {
        val instruction = listOfNotNull(title, text).joinToString(" ").trim()
        if (instruction.isEmpty()) return null

        // Maneuver first, so the distance gate can special-case arrivals.
        val maneuver = maneuverOverride?.takeIf { it in 1..49 }
            ?: ManeuverTextMap.classify(instruction)

        // Distance to the next maneuver. Cascade EVERY field before gating — apps
        // differ (title/text for most, subText for some). If there's genuinely no
        // distance anywhere, accept the frame ONLY for an arrival (icon 48) so the
        // cluster can show "arrived"; otherwise it isn't a nav frame.
        val dist = NavTextParse.distanceMeters(title)
            ?: NavTextParse.distanceMeters(text)
            ?: NavTextParse.distanceMeters(subText)
            ?: NavTextParse.distanceMeters(bigText)
            ?: if (maneuver == 48) 0 else return null
        // Raw road; transliteration is centralized at the controller choke point.
        val road = roadFrom(title) ?: roadFrom(text) ?: ""

        // remaining time / distance — from the ETA fields (subText/bigText), text as fallback
        val remTime = NavTextParse.timeSeconds(subText)
            ?: NavTextParse.timeSeconds(bigText)
            ?: NavTextParse.timeSeconds(text)
        val remDist = NavTextParse.distanceMeters(subText)
            ?: NavTextParse.distanceMeters(bigText)

        return NavGuidance(
            maneuverIcon = maneuver,
            distanceMeters = dist,
            roadName = road,
            remainingDistanceMeters = remDist,
            remainingTimeSeconds = remTime,
            source = source,
            rawManeuver = if (maneuverOverride != null) "notif[icon=$maneuverOverride]:'$instruction'"
            else "notif:'$instruction'",
        )
    }

    // A trailing ETA clock ("… - 2:45 PM" / "… - 14:30 ETA") is not part of the street.
    private val ETA_SUFFIX = Regex("""\s[-–—]\s*\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?(?:\s*ETA)?\s*$""")

    // A candidate that is ONLY a distance ("500 m", "1.2 km") is not a street name.
    private val DISTANCE_ONLY = Regex("""^[\d.,]+\s*(?:m|km|mi|ft|км|м|米)$""", RegexOption.IGNORE_CASE)

    // A candidate that STARTS with a maneuver/status verb is the instruction, not a street.
    // NB: "onto"/"toward" are NOT here — by the time cleanRoad() runs we've already
    // split on " onto "/" toward ", so a street legitimately NAMED "Onto St"/"Toward
    // Rd" must not be rejected by the post-separator validator.
    private val MANEUVER_OR_STATUS = Regex(
        """^\s*(turn|head|continue|keep|take|merge|exit|make|slight|sharp|u-?turn|enter|leave|go\b|follow|use|at the|drive|proceed|rerouting|recalculat|starting|searching|arriv|you have|in \d)""",
        RegexOption.IGNORE_CASE,
    )

    // An ETA / time-budget line ("5 min · 1.2 km", "14:30") is never a street name.
    private val TIME_LIKE = Regex("""\b\d{1,2}:\d{2}\b|\b\d+\s*(?:mins?|hrs?|hours?|h|мин|ч)\b|·""", RegexOption.IGNORE_CASE)

    /** Validate a road candidate: strip a trailing ETA clock, then reject it if it
     *  is empty / distance-only / a maneuver-status line / an ETA line. Returning
     *  null (rather than the bogus text) lets [parse] degrade to an empty road —
     *  the keepalive holds the prior cluster contents — instead of painting a
     *  distance or ETA where the street should be. */
    private fun cleanRoad(candidate: String?): String? {
        if (candidate.isNullOrBlank()) return null
        val r = ETA_SUFFIX.replace(candidate, "").trim()
        if (r.isEmpty()) return null
        if (DISTANCE_ONLY.containsMatchIn(r)) return null
        if (MANEUVER_OR_STATUS.containsMatchIn(r)) return null
        if (TIME_LIKE.containsMatchIn(r)) return null
        return r
    }

    /** "Turn left onto Main St" → "Main St"; "Head to Elm Rd" → "Elm Rd". Returns
     *  null for a blank / distance-only / ETA / maneuver-status field — so the bogus
     *  value never reaches the cluster's road line. */
    internal fun roadFrom(s: String?): String? {
        if (s.isNullOrBlank()) return null
        val lower = s.lowercase()
        for (sep in ROAD_SEPARATORS) {
            val i = lower.indexOf(sep)
            if (i >= 0) {
                val cleaned = cleanRoad(s.substring(i + sep.length))
                if (cleaned != null) return cleaned
            }
        }
        // no separator: the whole field is the candidate (rejected if not a street)
        return cleanRoad(s)
    }
}
