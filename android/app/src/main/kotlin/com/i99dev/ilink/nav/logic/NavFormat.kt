package com.i99dev.ilink.nav.logic

import java.util.Locale

/**
 * Distance + time formatting for HUD text, verbatim from the reference's inline
 * formatters (metric only — the APK has no imperial path). Pure + host-testable.
 *
 * Deviation from the reference (intentional, production): the reference used default-locale
 * `String.format`, which renders "1,5 km" on comma-decimal cars. We pin
 * [Locale.US] so the cluster always shows "1.5 km".
 */
object NavFormat {

    /** meters → "750 m" (< 1 km) or "1.5 km". */
    fun distance(meters: Int): String =
        if (meters < 1000) "$meters m" else String.format(Locale.US, "%.1f km", meters / 1000.0f)

    /** seconds → "45 min" (< 1 h) or "2h 5m". */
    fun time(seconds: Int): String {
        val totalMin = seconds / 60
        val h = totalMin / 60
        val min = totalMin % 60
        return if (h <= 0) "$min min" else "${h}h ${min}m"
    }
}
