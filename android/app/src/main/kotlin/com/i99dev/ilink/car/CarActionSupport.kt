package com.i99dev.ilink.car

/**
 * Per-action support classification — what `CarCommandRouter` consults
 * before issuing the dispatch. Lets us short-circuit known-bad
 * actions without paying the rate-limit + bridge round-trip cost.
 *
 * The map below seeds the *static* expectation; the daemon stays the
 * authority and an unexpected `UNSUPPORTED → success` is folded back
 * into the [CapabilityRegistry] backend overlay via the probe
 * sync (so the next boot upgrades the entry).
 *
 * Action classes (driving the fallback strategy):
 *   * [Class.BASIC]    — safe, low-risk standard actuators (door
 *                        unlock/lock, AC power/fan/temp, basic
 *                        window). Tried even on Tier-5 unknown.
 *   * [Class.ADVANCED] — sub-trim-specific actuators (massage,
 *                        heated seats, HUD). Tried on Tier-1..4;
 *                        on Tier-5 unknown, surface a "best-effort"
 *                        warning to the user before dispatching.
 *   * [Class.CRITICAL] — actions that could risk damage on the
 *                        wrong actuator wiring (sunroof, mirror
 *                        fold, hood). Pre-deny on Tier-5 unknown
 *                        even though the daemon would catch it —
 *                        the speed win is worth blocking a probe
 *                        attempt on a path that could fail loud.
 */
object CarActionSupport {

    enum class Class { BASIC, ADVANCED, CRITICAL }

    enum class Support {
        SUPPORTED,
        UNSUPPORTED,
        /** Static seed says we don't know — try, let the daemon
         *  authority decide, fold the result back into the probe.
         *  This is the common case for unfamiliar trims. */
        UNKNOWN_ASSUME_SUPPORTED,
    }

    /** Which class an action belongs to. Used to pick the
     *  fallback strategy in [CarCommandRouter] when
     *  `profile.isFallback`. */
    fun classOf(actionId: String): Class = when {
        actionId in BASIC -> Class.BASIC
        actionId in CRITICAL -> Class.CRITICAL
        else -> Class.ADVANCED
    }

    /** Lookup support for [actionId] on a profile keyed at [key].
     *  Returns the per-trim entry when the seed has one; falls back
     *  to UNKNOWN_ASSUME_SUPPORTED for everything else (the daemon
     *  is the authority). */
    fun supportFor(key: ProfileKey, actionId: String): Support {
        val perTrim = SEED[key.toSeedKey()] ?: return Support.UNKNOWN_ASSUME_SUPPORTED
        return perTrim[actionId] ?: Support.UNKNOWN_ASSUME_SUPPORTED
    }

    /** Seed key — collapses a [ProfileKey] to the (variant, subTrim)
     *  pair the SEED map keys on. Fingerprint doesn't appear here:
     *  action support is hardware-determined, not ROM-determined,
     *  and a per-fingerprint table would be a maintenance trap.
     *  Empty subTrim falls back to the variant default. */
    private fun ProfileKey.toSeedKey(): Pair<String, String> =
        variantId to subTrim

    // ── Action class seeds ──────────────────────────────────────────
    // Curated lists — keep small. Anything not listed here is
    // ADVANCED by default (the fallback strategy is then
    // try-with-warning on Tier-5).

    private val BASIC: Set<String> = setOf(
        "lock_door",
        "unlock_door",
        "set_ac_power",
        "set_ac_fan_speed",
        "set_ac_temperature",
        "set_window_position",
    )

    private val CRITICAL: Set<String> = setOf(
        "set_sunroof",
        "fold_mirrors",
        "open_hood",
        "open_trunk_motor",
    )

    // ── Per-(variant, subTrim) static seed ──────────────────────────
    // Empirically known UNSUPPORTED entries from the byd/ research
    // dump. SUPPORTED entries are implicit (UNKNOWN_ASSUME_SUPPORTED
    // means "we'll try and let the daemon say"). New entries land
    // here when probe data confirms a new gap.

    private val SEED: Map<Pair<String, String>, Map<String, Support>> = mapOf(
        // L5 base / Navigator / Flagship / Ultra — no massage seats
        // (Flagship has them; Navigator + base do not).
        ("l5" to "navigator") to mapOf(
            "set_seat_massage" to Support.UNSUPPORTED,
            "set_seat_heat" to Support.UNSUPPORTED,
            "set_hud_brightness" to Support.UNSUPPORTED,
        ),
        ("l5" to "ultra") to mapOf(
            "set_seat_massage" to Support.UNSUPPORTED,
        ),
        ("l5" to "flagship") to mapOf(
            // Flagship has the full feature set — no UNSUPPORTED
            // seed entries.
        ),
        ("l5" to "lidar") to mapOf(
            // Lidar variant — full L5L feature set.
        ),
        // L8 base — single trim; full feature set.
        ("l8" to "base") to mapOf(),
        // L7 base — no HUD per byd/l7 capture.
        ("l7" to "base") to mapOf(
            "set_hud_brightness" to Support.UNSUPPORTED,
        ),
        // HAN L base.
        ("han_l" to "base") to mapOf(),
    )
}
