package com.i99dev.ilink.car

/**
 * Hardware sub-trim within a
 * [com.i99dev.ilink.car.profiles.CarProfile]'s `variantId`. Splits
 * "L5" into Flagship / Navigator (Ultra and Lidar are separate
 * variantIds, not sub-trims of L5); collapses single-trim variants
 * (L8, L7, HAN L) to `Base`.
 *
 * Mirror of `app/domain/vehicle_capabilities/constants.py` SUB_TRIMS;
 * the SDK drift check covers it. New entries are additive only.
 *
 * `wire` is what gets serialised on the platform channel + sent to
 * the backend `vehicle-capabilities` endpoint. Empty string for
 * `null` so wire shape stays stringly-typed (the backend treats
 * `""` as "trim-level aggregate row").
 */
enum class SubTrim(val wire: String) {
    FLAGSHIP("flagship"),
    NAVIGATOR("navigator"),
    ULTRA("ultra"),
    LIDAR("lidar"),
    BASE("base"),
    ;

    companion object {
        /** Reverse map for lookup by wire string. Returns null for
         *  empty / unknown — callers treat that as "trim-level
         *  aggregate". */
        fun fromWire(s: String?): SubTrim? = when (s) {
            null, "" -> null
            else -> entries.firstOrNull { it.wire == s }
        }
    }
}
