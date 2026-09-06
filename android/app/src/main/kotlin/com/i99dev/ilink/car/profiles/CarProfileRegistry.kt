package com.i99dev.ilink.car.profiles

import com.i99dev.ilink.car.profiles.definitions.BYD_HAN_L_PROFILE
import com.i99dev.ilink.car.profiles.definitions.F_SERIES_PROFILE
import com.i99dev.ilink.car.profiles.definitions.GENERIC_DI50
import com.i99dev.ilink.car.profiles.definitions.GENERIC_DI51
import com.i99dev.ilink.car.profiles.definitions.GENERIC_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD5_LIDAR_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD5_NAVIGATOR_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD5_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD5_ULTRA_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD7_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD8_DRONEKIT_PROFILE
import com.i99dev.ilink.car.profiles.definitions.LEOPARD8_PROFILE
import com.i99dev.ilink.car.profiles.definitions.SEALION6_DMI_PROFILE
import com.i99dev.ilink.car.profiles.definitions.SEALION6_EV_PROFILE
import com.i99dev.ilink.car.profiles.definitions.SONG_PLUS_PROFILE
import com.i99dev.ilink.car.profiles.definitions.SONG_PLUS_SD_PROFILE
import com.i99dev.ilink.car.profiles.definitions.QIN_L_PROFILE
import com.i99dev.ilink.car.profiles.definitions.QIN_PLUS_PROFILE
import com.i99dev.ilink.car.profiles.definitions.SONG_PRO_PROFILE
import java.util.concurrent.atomic.AtomicReference

/**
 * Single accessor for every trim's [CarProfile].
 *
 * Three tiers:
 *   * **Probe-validated** trims have a dedicated definition file
 *     under `car/profiles/definitions/` and a real [CarProfile]
 *     entry in [ALL] (live empirical data).
 *   * **Stub** trims (every other BYD `VehicleCarType`) carry no
 *     empirical data. They are *derived on demand* by [stubProfile]
 *     — `GENERIC_PROFILE` plus the friendly name from [STUB_TRIMS].
 *     No stored object, no registry row: one name-map entry is the
 *     entire stub. (This replaced 20 hand-written `BrandStubs.kt`
 *     `CarProfile.copy` vals — behaviour-identical, far less
 *     boilerplate.)
 *   * **Runtime DiLink fallback** — a fully-unknown car still
 *     surfaces its generation token (`"di5.0"`/`"di5.1"`) at the
 *     head of the model-id chain, so [DILINK_FALLBACK] hands it a
 *     generation-correct, cluster-conservative Generic instead of
 *     the blind permissive one (fixes silent Di5.0 cast failure).
 *
 * Lookup is O(1) (`Map` get for reals, `Map` get for stub names);
 * the active-car cache lets the hot path skip variantId resolution.
 * Callers that always read the current car should prefer
 * [forActiveCar] over [forVariant] — same result, fewer ops.
 *
 * Adding a new BYD trim:
 *   * Probe-validated: create `definitions/<TrimName>.kt` with a
 *     top-level `internal val <NAME>_PROFILE = CarProfile(...)`,
 *     add the import + an entry in [ALL], and (if the variantId is
 *     new) update `_resolveModel` in `model_detector.dart`. If the
 *     variantId was previously a stub, delete its [STUB_TRIMS] row.
 *   * Stub only (friendly name + telemetry, no live data yet): add
 *     one `"<variantId>" to "<Friendly Name>"` row to [STUB_TRIMS].
 *
 * No other consumer needs to be touched.
 */
object CarProfileRegistry {

    /**
     * Probe-validated trims only — every entry is backed by live
     * empirical data. Keyed on variantId. Stub trims are NOT here
     * (see [STUB_TRIMS] / [stubProfile]); `null` and any
     * fully-unknown variantId fall through to [GENERIC_PROFILE] in
     * [forVariant].
     */
    private val ALL: Map<String, CarProfile> = listOf(
        LEOPARD8_PROFILE,
        LEOPARD8_DRONEKIT_PROFILE,
        LEOPARD5_PROFILE,
        LEOPARD5_NAVIGATOR_PROFILE,
        LEOPARD5_LIDAR_PROFILE,
        LEOPARD5_ULTRA_PROFILE,
        LEOPARD7_PROFILE,
        BYD_HAN_L_PROFILE,
        SONG_PLUS_PROFILE,
        SONG_PLUS_SD_PROFILE,
        SONG_PRO_PROFILE,
        QIN_L_PROFILE,
        QIN_PLUS_PROFILE,
        SEALION6_DMI_PROFILE,
        SEALION6_EV_PROFILE,
        F_SERIES_PROFILE,
    ).associateBy { it.variantId!! }

    /**
     * variantId → friendly name for every BYD `VehicleCarType` the
     * detector can resolve but for which no live probe data exists
     * yet. Mirrors the 21-string `VehicleCarType` enum minus the
     * trims already in [ALL]. A stub is *only* a name — its profile
     * is `GENERIC_PROFILE` + this name, synthesized by [stubProfile]
     * on demand.
     *
     * Why keep the name rather than fall straight through to
     * Generic: the Settings / About friendly name (read by
     * `CapabilityRegistry.friendlyNameOf`) must show "BYD Tang",
     * not "Generic BYD DiLink". (Sentry trim tags come from the
     * Dart detector, not the profile — see the dead-`triage`
     * removal.)
     *
     * Promotion path: when a live unit surfaces telemetry, create
     * its `definitions/<Trim>.kt`, add it to [ALL], and delete its
     * row here.
     */
    private val STUB_TRIMS: Map<String, String> = mapOf(
        // ── Dynasty (王朝) ──
        "han" to "BYD Han",
        "tang" to "BYD Tang",
        "song" to "BYD Song",
        "qin" to "BYD Qin",
        "xia" to "BYD Xia",
        // ── Ocean (海洋) ──
        "seal" to "BYD Seal",
        "sealion" to "BYD Sealion",
        "dolphin" to "BYD Dolphin",
        // ── Denza (腾势) ──
        "denza_n7" to "Denza N7",
        "denza_n8" to "Denza N8",
        "denza_n9" to "Denza N9",
        "denza_d9" to "Denza D9",
        "denza_z9" to "Denza Z9",
        // ── Yangwang (仰望, R-brand) ──
        "yangwang_r1" to "Yangwang R1",
        "yangwang_r2" to "Yangwang R2",
        "yangwang_r3" to "Yangwang R3",
        "yangwang_r4" to "Yangwang R4",
        // ── FangChengBao (方程豹) family-level fallbacks ──
        "fcbsf" to "FangChengBao FCBSF",
        "fcbsq" to "FangChengBao FCBSQ",
        "fcbure" to "FangChengBao FCBURE",
    )

    /**
     * Synthesize the stub [CarProfile] for [variantId]: the friendly
     * name from [STUB_TRIMS] layered onto a **generation-correct
     * base**, derived from the DiLink token carried in [chain] (the
     * detector's `[variant, dilinkFamily]` model-id chain).
     *
     * Why generation-aware: a known-but-unprofiled nameplate (Tang,
     * Sealion, Han, …) used to fall to the plain permissive
     * `GENERIC_PROFILE` (`passenger = Fission`, family `Unknown`).
     * On a Di5.0 BYD-container car that is the WRONG transport —
     * `setLaunchDisplayId` is dropped on the container virtuals, so a
     * Fission/am-start passenger or cluster launch creates an
     * invisible task and silently never casts (see `docs/50/05`).
     * Folding the live `"di5.0"`/`"di5.1"` token onto [GENERIC_DI50]
     * / [GENERIC_DI51] gives the stub the correct DiShare-vs-am-start
     * transport + container display topology while keeping the
     * conservative empty-cluster caps of the generic fallback. When
     * the chain carries no token (truly-unknown generation) it falls
     * back to plain `GENERIC_PROFILE` — behaviour-identical to the
     * old stored `BrandStubs` definitions.
     *
     * Precondition: `variantId in STUB_TRIMS`.
     */
    private fun stubProfile(
        variantId: String,
        chain: List<String> = emptyList(),
    ): CarProfile {
        val base = chain.firstNotNullOfOrNull { DILINK_FALLBACK[it] } ?: GENERIC_PROFILE
        return base.copy(
            variantId = variantId,
            familyName = STUB_TRIMS.getValue(variantId),
        )
    }

    /**
     * Runtime DiLink-generation fallback. When the variant is
     * unknown, the Dart detector still puts the generation token
     * (`ro.vehicle.type` → `"di5.0"` / `"di5.1"`) at the head of the
     * model-id chain, so it arrives here as [forVariant]'s argument.
     * Mapping it to a generation-correct, cluster-conservative
     * Generic lets an unprofiled BYD car cast correctly without a
     * per-trim file. Pure: the token is the input, so the resolver
     * is unit-tested with no Android I/O. See `Generic.kt`.
     * Profiled trims never reach this (they hit [ALL]); only
     * genuinely-unknown cars do.
     */
    private val DILINK_FALLBACK: Map<String, CarProfile> = mapOf(
        "di5.0" to GENERIC_DI50,
        "di5.1" to GENERIC_DI51,
    )

    /**
     * Active-car cache — populated by `ModelDetectorChannel` once
     * detection resolves at boot. Read by every host consumer that
     * needs "the current car" without re-resolving the variantId.
     * AtomicReference because the boot read happens off the main
     * thread.
     */
    private val active: AtomicReference<CarProfile> = AtomicReference(GENERIC_PROFILE)

    /**
     * Single-id lookup — the head of the model-id chain only. Kept
     * for callers that hold just a variantId (capability seeds, the
     * Settings override path) and for the unit tests. Delegates to
     * [forChain]; a lone id carries no generation token, so a stub
     * resolved here stays generation-agnostic (plain Generic base) —
     * unchanged from the original behaviour. Prefer [forChain] /
     * [forActiveCar] anywhere the full `[variant, dilinkFamily]`
     * chain is available so stubs resolve generation-correctly.
     */
    fun forVariant(variantId: String?): CarProfile =
        forChain(listOfNotNull(variantId))

    /**
     * O(1) chain lookup, finest-to-coarsest, on the detector's
     * `[variant, dilinkFamily]` model-id chain (head = finest):
     *   1. probe-validated head → its [ALL] entry;
     *   2. known stub head → [stubProfile] layered on the chain's
     *      DiLink token (generation-correct transport + topology);
     *   3. runtime DiLink token head (`"di5.0"`/`"di5.1"`) →
     *      [DILINK_FALLBACK] (generation-correct, cluster-safe);
     *   4. anything else (including an empty chain) → [GENERIC_PROFILE].
     * Never throws — callers always get a usable profile back.
     */
    fun forChain(ids: List<String>): CarProfile {
        val head = ids.firstOrNull() ?: return GENERIC_PROFILE
        ALL[head]?.let { return it }
        if (head in STUB_TRIMS) return stubProfile(head, ids)
        DILINK_FALLBACK[head]?.let { return it }
        return GENERIC_PROFILE
    }

    /**
     * The profile for the currently-detected car. Set once at
     * boot via [setActive] from the model detector's resolution.
     * Reads are lock-free.
     */
    fun forActiveCar(): CarProfile = active.get()

    /**
     * Called by `MiniAppDispatcher.setModelIds` after `ModelDetector
     * .detect()` resolves the car. Takes the FULL `[variant,
     * dilinkFamily]` chain (not just the head) so [forActiveCar]
     * resolves stubs generation-correctly. Idempotent — subsequent
     * calls overwrite (e.g. a profile-override path triggered by
     * Settings).
     */
    fun setActive(ids: List<String>) {
        active.set(forChain(ids))
    }

    /** Test-only: reset to Generic. */
    fun resetActiveForTesting() {
        active.set(GENERIC_PROFILE)
    }

    /** Test-only: every known-trim profile — probe-validated +
     *  every synthesized stub + both runtime DiLink fallbacks +
     *  Generic. Used by the per-variant fixture test. */
    fun knownProfilesForTesting(): List<CarProfile> =
        ALL.values.toList() +
            STUB_TRIMS.keys.map { stubProfile(it) } +
            DILINK_FALLBACK.values +
            GENERIC_PROFILE
}
