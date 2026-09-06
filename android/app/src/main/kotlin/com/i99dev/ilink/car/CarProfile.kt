package com.i99dev.ilink.car

/**
 * The single object both gates ([CarCommandRouter] for actions; the
 * mini-app catalog filter for capabilities) consult to answer "what
 * works on this car right now". Resolved by [CarProfileRegistry]
 * with a 5-tier fallback chain so even unidentified cars get a
 * usable answer.
 *
 * The fields are deliberately broad — older callers that only need
 * the capability bitmask still get [capabilityBits] alone; new
 * callers that want action support consult [CarActionSupport] with
 * [key] (the action-support map is keyed on (variant, subTrim) and
 * doesn't depend on fingerprint).
 *
 * Mirrored on Dart side as `lib/core/car/car_profile.dart`.
 */
data class CarProfile(
    /** The four-tuple identity this profile resolves. Empty-string
     *  slots indicate which fallback tier we landed on. */
    val key: ProfileKey,
    /** True when the resolver couldn't find a precise (fingerprint-
     *  level) match. Both gates use this to decide between strict
     *  enforcement vs. permissive try-with-warning. */
    val isFallback: Boolean,
    /** Why the resolver fell back, or null on a precise hit. One of
     *  ``"unknown_fingerprint"`` / ``"unknown_sub_trim"`` /
     *  ``"unknown_variant"`` / ``"unknown_dilink"``. */
    val fallbackReason: String?,
    /** Friendly UI label — "Leopard 5 Flagship" etc. Carried so the
     *  picker doesn't need to re-derive it from the key. */
    val friendlyName: String,
    /** Capability bitmask — fed straight to the catalog filter's
     *  [hasAllCapabilities] check. Hot path. */
    val capabilityBits: Long,
    /** Source of the bitmask, for observability. ``"backend"``
     *  when the backend overlay had a precise hit;
     *  ``"backend_fallback"`` for an aggregate; ``"static"`` when
     *  the compiled-in seed answered. */
    val capabilitiesSource: String,
)
