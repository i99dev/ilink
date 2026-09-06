package com.i99dev.ilink.nav.domain

/**
 * One vehicle position sample, WGS-84 degrees. Pure data, host-JVM testable, no
 * Android imports — the Android `Location` read lives behind
 * [com.i99dev.ilink.nav.ingest.NavLocationCache], which hands back this type so
 * the rest of the nav stack never touches a platform class.
 *
 * [heading] is course over ground in degrees clockwise from true north (0..360),
 * or null when the fix has no bearing (a stationary car usually reports none).
 */
data class NavFix(
    val lat: Double,
    val lon: Double,
    val heading: Double? = null,
) {
    /** Guards against the 0/0 "null island" and out-of-range junk some providers
     *  emit before they have a real fix. */
    val isPlausible: Boolean
        get() = lat in -90.0..90.0 && lon in -180.0..180.0 && !(lat == 0.0 && lon == 0.0)

    companion object {
        /**
         * THE one "do we have a usable position?" decision, so every consumer
         * answers it identically. Nullable-in, nullable-out: returns null when
         * either coordinate is absent OR the pair fails [isPlausible] — i.e.
         * exactly the cases in which a transport must fall back to its previous,
         * position-free behaviour.
         *
         * Callers must NOT re-derive this: if the guideline said "real position"
         * and the codec said "stub", a frame would carry two different positions.
         */
        fun of(lat: Double?, lon: Double?, heading: Double? = null): NavFix? {
            if (lat == null || lon == null) return null
            if (!lat.isFinite() || !lon.isFinite()) return null
            return NavFix(lat, lon, heading).takeIf { it.isPlausible }
        }
    }
}
