package com.i99dev.ilink.car

/**
 * Four-tuple identity that uniquely keys a [CarProfile] across the
 * fleet. Both gates ([CarCommandRouter] for actions; the catalog
 * filter for mini-app caps) consult [CarProfileRegistry] with this
 * key on every cold boot.
 *
 * The tuple is ordered most-coarse → most-precise on purpose so the
 * fallback chain in [CarProfileRegistry.resolve] can strip slots
 * right-to-left (fingerprint → subTrim → variantId) without
 * re-allocating.
 *
 * Serialisation: shipped to the backend `vehicle-capabilities`
 * endpoint as the camelCase JSON shape
 * `{dilinkFamily, variantId, subTrim, fingerprint}`. Empty-string
 * slots are valid wire values and represent aggregate rows.
 *
 * Mirrored on the Dart side as `lib/core/car/profile_key.dart`.
 */
data class ProfileKey(
    /** ``di5.0`` / ``di5.1`` / ``unknown``. Always populated; the
     *  detector falls back to ``unknown`` rather than empty. */
    val dilinkFamily: String,
    /** Trim id (``l5`` / ``l8`` / ``l5l`` / ...). Empty for the
     *  DiLink-generation default fallback. */
    val variantId: String = "",
    /** Hardware sub-trim wire string (``flagship`` / ``base`` / ...
     *  via [SubTrim.wire]). Empty for the trim-level aggregate. */
    val subTrim: String = "",
    /** ``ro.build.fingerprint`` exactly as Android reports it. Empty
     *  for the sub-trim aggregate. */
    val fingerprint: String = "",
) {
    /** Wire shape — the JSON object the platform channel + backend
     *  both consume. Stable field order so MethodChannel marshalling
     *  doesn't reshape it. */
    fun toMap(): Map<String, String> = mapOf(
        "dilinkFamily" to dilinkFamily,
        "variantId" to variantId,
        "subTrim" to subTrim,
        "fingerprint" to fingerprint,
    )

    /** Strip the rightmost-set slot — the fallback walk. Returns null
     *  when this is already the DiLink-default key (no further
     *  fallback exists). */
    fun stripOne(): ProfileKey? = when {
        fingerprint.isNotEmpty() -> copy(fingerprint = "")
        subTrim.isNotEmpty() -> copy(subTrim = "")
        variantId.isNotEmpty() -> copy(variantId = "")
        else -> null
    }

    companion object {
        /** Tier-5 unknown. Hosts that can't identify the car at all
         *  (dev runner, web, non-BYD ROM) fall here. */
        val Unknown = ProfileKey(dilinkFamily = "unknown")
    }
}
