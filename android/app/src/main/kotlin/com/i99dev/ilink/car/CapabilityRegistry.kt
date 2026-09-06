package com.i99dev.ilink.car

/**
 * Single source of truth for "what can the active car actually do".
 *
 * Resolution chain (5 tiers, evaluated cheap → expensive):
 *
 *   1. **Backend precise** — overlay row keyed on the full
 *      [ProfileKey] (dilink × variant × subTrim × fingerprint). This
 *      is empirical truth aggregated from probes across the whole
 *      fleet on this exact ROM.
 *   2. **Backend sub-trim aggregate** — same ProfileKey with empty
 *      `fingerprint`. UNION of every probe on this hardware sub-trim
 *      regardless of ROM. Useful when the host boots on a brand-new
 *      ROM build for a known sub-trim.
 *   3. **Backend trim aggregate** — same again with empty `subTrim`.
 *      Used when the sub-trim couldn't be resolved.
 *   4. **Backend DiLink-default** — empty variant + subTrim. The
 *      DiLink-generation floor; useful for unknown trims on a
 *      known DiLink generation.
 *   5. **Static seed** — compiled-in derivation from the per-trim
 *      [com.i99dev.ilink.car.profiles.CarProfile]. Works offline,
 *      ships in the APK; never wrong about cars we already profiled.
 *
 * The seed translates each trim's
 * [com.i99dev.ilink.car.profiles.CapabilityProfile] into the SDK's
 * flat capability strings via `CapabilityProfile.toCapabilityNames()`.
 * Single source of truth for per-trim caps lives in
 * [com.i99dev.ilink.car.profiles.CarProfileRegistry]; capability
 * bits are a *derived* view that mini-apps see through
 * `display.list`.
 *
 * Wire shape: hosts emit a single [Long] in the `display.list`
 * snapshot's `vehicle.capabilityBits` field, plus the readable
 * `vehicle.capabilities` array for SDK consumers that don't want to
 * round-trip the bitmask.
 */
object CapabilityRegistry {

    /** In-memory backend overlay. Populated by `CapabilityProber.sync()`
     *  once a successful backend roundtrip lands; null until then.
     *  Read on every [resolve] call — atomic reference for lock-free
     *  reads on the hot path. */
    @Volatile
    private var backendOverlay: Map<String, Long>? = null

    /**
     * Active [CarProfile] for [key]. Walks the 5-tier fallback chain
     * and stamps `isFallback` + `fallbackReason` on the result.
     *
     * Hot path — both gates call this on every dispatch / catalog
     * render. Caching is the caller's responsibility (the Dart side
     * caches via [carProfileProvider]).
     */
    fun resolve(key: ProfileKey): CarProfile {
        val overlay = backendOverlay

        // Tier 1 — backend precise (full ProfileKey).
        if (overlay != null && key.fingerprint.isNotEmpty()) {
            overlay[key.toOverlayKey()]?.let { bits ->
                return CarProfile(
                    key = key,
                    isFallback = false,
                    fallbackReason = null,
                    friendlyName = friendlyNameOf(key),
                    capabilityBits = bits,
                    capabilitiesSource = "backend",
                )
            }
        }
        // Tier 2-4 — strip slots right-to-left.
        if (overlay != null) {
            var probe = key.stripOne()
            var reason: String? = "unknown_fingerprint"
            while (probe != null) {
                overlay[probe.toOverlayKey()]?.let { bits ->
                    return CarProfile(
                        key = probe!!,
                        isFallback = true,
                        fallbackReason = reason,
                        friendlyName = friendlyNameOf(key), // friendlyName comes from
                        // the original key — the user's car hasn't
                        // changed, only the resolution tier did.
                        capabilityBits = bits,
                        capabilitiesSource = "backend_fallback",
                    )
                }
                reason = nextStripReason(probe)
                probe = probe.stripOne()
            }
        }

        // Tier 5 — static seed. The seed itself encodes its own
        // fallback (Generic for null variant), so this always
        // returns *some* answer. Mark as fallback when we couldn't
        // resolve a precise variant + subTrim combo.
        val seedBits = staticSeed(key.variantId.takeIf { it.isNotEmpty() })
        val isStaticFallback = key.variantId.isEmpty() || key.subTrim.isEmpty()
        return CarProfile(
            key = key,
            isFallback = isStaticFallback,
            fallbackReason = if (isStaticFallback) "static_default" else null,
            friendlyName = friendlyNameOf(key),
            capabilityBits = seedBits,
            capabilitiesSource = "static",
        )
    }

    /**
     * Replace the backend overlay atomically. Called by
     * `CapabilityProber.sync()` on each successful backend response.
     * Keys: ``"<dilink>::<variant>::<subTrim>::<fingerprint>"`` with
     * empty-string slots representing the aggregate rows the
     * resolver walks through.
     */
    fun setBackendOverlay(overlay: Map<String, Long>) {
        backendOverlay = overlay
    }

    /** Test seam — clears the overlay so test isolation is clean. */
    fun resetForTesting() {
        backendOverlay = null
    }

    /**
     * Legacy facade — looks up bits using only `(variantId,
     * fingerprint)`. Used by [DisplayPlatformPlugin.capabilityBits]
     * which doesn't know about sub-trim / dilink yet (the new
     * canonical path is the [CarProfilePlatformPlugin] channel).
     *
     * Kept thin: builds a [ProfileKey] with empty subTrim + the
     * detector's dilink, calls [resolve], returns the bitmask. Both
     * paths land at the same backend overlay + static seed, so the
     * answer matches what [resolve] would give for the same trim.
     */
    fun bitsForVariant(variantId: String?, fingerprint: String? = null): Long {
        val key = ProfileKey(
            dilinkFamily = "unknown", // legacy callers don't carry dilink;
                                       // the resolve walk falls through to
                                       // static seed regardless.
            variantId = variantId ?: "",
            subTrim = "",
            fingerprint = fingerprint ?: "",
        )
        return resolve(key).capabilityBits
    }

    /**
     * Derive the seed bitmask for [variantId] by reading its
     * [com.i99dev.ilink.car.profiles.CarProfile.capabilities]
     * entry in [com.i99dev.ilink.car.profiles.CarProfileRegistry].
     * Single source of truth for what each trim is granted — mapping
     * is documented inline at each per-trim file under
     * `car/profiles/definitions/`.
     */
    fun staticSeed(variantId: String?): Long {
        val caps = com.i99dev.ilink.car.profiles.CarProfileRegistry
            .forVariant(variantId)
            .capabilities
            .toCapabilityNames()
        return VehicleCapability.bitsOf(caps)
    }

    private fun ProfileKey.toOverlayKey(): String =
        "$dilinkFamily::$variantId::$subTrim::$fingerprint"

    private fun nextStripReason(after: ProfileKey): String? = when {
        // After stripping fingerprint, the next strip removes subTrim.
        after.fingerprint.isEmpty() && after.subTrim.isNotEmpty() -> "unknown_sub_trim"
        // After subTrim, the next strip removes variantId.
        after.subTrim.isEmpty() && after.variantId.isNotEmpty() -> "unknown_variant"
        // After variantId, no further strip.
        else -> "unknown_dilink"
    }

    private fun friendlyNameOf(key: ProfileKey): String {
        val variant = key.variantId.takeIf { it.isNotEmpty() }
        val profile = com.i99dev.ilink.car.profiles.CarProfileRegistry.forVariant(variant)
        val sub = SubTrim.fromWire(key.subTrim)
        val base = profile.familyName
        // Append sub-trim when present — "Leopard 5 Flagship",
        // "Leopard 5 Navigator", etc. Single-trim variants
        // (L8 base, L7 base) drop the suffix to stay compact.
        return when (sub) {
            null, SubTrim.BASE -> base
            else -> "$base ${sub.wire.replaceFirstChar { it.titlecase() }}"
        }
    }

    // `isDi50Trim` and `isL5Family` were removed when the per-variant
    // capability table moved to `VariantCapabilityProfile`. The facts
    // they encoded — "L5/L5U use synthetic-swipe for passenger cast",
    // "L5 family has cluster-icons" — are now expressed as typed
    // entries on each variant's profile. Adding a new variant no
    // longer requires editing helpers in this file.
}
