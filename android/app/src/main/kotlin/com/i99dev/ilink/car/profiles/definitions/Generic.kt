package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.CapabilityProfile
import com.i99dev.ilink.car.profiles.CarProfile
import com.i99dev.ilink.car.profiles.ClusterCapability
import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.DisplayProfile
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.car.profiles.Powertrain

/**
 * Generic catch-all — the fallback profile for variantIds with
 * neither a probe-validated entry in
 * [com.i99dev.ilink.car.profiles.CarProfileRegistry.ALL] nor a
 * stub-name row in `CarProfileRegistry.STUB_TRIMS` (stub trims get
 * a Generic-shaped profile *plus* a friendly name), including
 * `null`.
 *
 * Permissive defaults: assumes both passenger surface AND cluster
 * pixel-overlay are reachable until a real probe says otherwise.
 * The `DisplayClassifier` still has the final say on actual
 * rendering, so an over-eager grant here just shows up as a
 * runtime "no cap delivered" rather than a crash.
 *
 * The classifier's `secondaryDisplayOwners` is intentionally empty
 * on Generic: we refuse to auto-classify fission slots on an
 * unprofiled trim because the BYD-vs-XDJA container distinction
 * carries trim-specific role semantics (BYD-container → passenger
 * on Di5.0 vs XDJA-container → cluster on Di5.1). Without a
 * matched profile we fall back to the name-keyword heuristic and
 * leave the user to run the manual calibration tour.
 *
 * Mirrors pre-refactor `VehicleProfile.Generic` +
 * `VariantCapabilityProfile.Generic` for byte-identical behavior.
 *
 * RUNTIME DILINK FALLBACK (implemented — see [GENERIC_DI50] /
 * [GENERIC_DI51]): the generation fork is the single bit
 * `capabilities.passenger == DishareQuickShare`, read once by
 * [com.i99dev.ilink.display.DisplayLaunchPlanner]. An *unknown*
 * BYD car still casts correctly because the live DiLink-generation
 * signal (`ro.vehicle.type`, resolved by the Dart detector into the
 * model-id chain) already arrives at
 * `CarProfileRegistry.forVariant` as the literal token `"di5.0"` /
 * `"di5.1"` when the variant is unknown. The registry maps those
 * tokens to [GENERIC_DI50] / [GENERIC_DI51] — Generic shape with
 * the generation-correct passenger transport and a **conservative
 * empty cluster** (we never claim an unprobed cluster surface).
 * This stayed untestable until the token already flowed into the
 * *pure* `forVariant`; it now does, so the resolver is unit-tested
 * directly (no Android I/O, no mock) — the failure mode that
 * deferred this is gone. Profiled trims never hit this path
 * (they resolve in `ALL`); only genuinely-unknown cars do.
 */
internal val GENERIC_PROFILE = CarProfile(
    variantId = null,
    familyName = "Generic BYD DiLink",
    dilinkFamily = DilinkFamily.Unknown,
    powertrain = Powertrain.Unknown,
    displays = DisplayProfile(
        showCluster = true,
        showFission2 = true,
        hiddenDisplayIds = emptySet(),
        overrideLabels = emptyMap(),
        cursorRemap = emptyMap(),
        inputRemap = emptyMap(),
        zoomRemap = emptyMap(),
        secondaryDisplayOwners = emptyMap(),
    ),
    capabilities = CapabilityProfile(
        universalCaps = STANDARD_UNIVERSAL_CAPS,
        passenger = PassengerTransport.Fission,
        cluster = setOf(ClusterCapability.Pixel),
    ),
)

/**
 * Unknown car, but `ro.vehicle.type` says **Di5.0** (BYD container).
 * Returned by `CarProfileRegistry.forVariant("di5.0")` when no
 * variant/stub matched.
 *
 * Inherits the full [DI50_BYD_DISHARE] display topology — the BYD-
 * container layout (display 2 = FSE Co-pilot source, 3 = sibling
 * panel, 4 = Driver Dashboard cluster mirror) is uniform across
 * every Di5.0 trim seen in the wild (L5, Song PLUS, plus the
 * undocumented variants this generic catches). Means: cluster
 * touchpad routing, cursor overlay, and DiShare `cluster_tr` cast
 * all work on an unprofiled Di5.0 car without waiting for a
 * dedicated trim entry. The 2026-05-20 operator request that
 * surfaced this: "use di5.0 as the global path so more cars
 * benefit; keep di5.1 split with a different path."
 *
 * Capabilities stay **conservative (cluster = emptySet)**: we
 * never grant mini-app cluster caps on a trim with no live probe.
 * The profiled L5 / Song PLUS keep their real
 * `{DishareQuickShare, Icons}`; an unknown Di5.0 car does not.
 * Passenger transport stays `DishareQuickShare` (generation-
 * critical — `setLaunchDisplayId` is dropped on Di5.0 BYD-
 * container virtuals so DiShare is the only path that casts at
 * all).
 */
internal val GENERIC_DI50 = DI50_BYD_DISHARE.copy(
    variantId = null,
    familyName = "Generic BYD Di5.0",
    capabilities = DI50_BYD_DISHARE.capabilities.copy(
        cluster = emptySet(),
    ),
)

/**
 * Unknown car, but `ro.vehicle.type` says **Di5.1** (XDJA / framework
 * fission). Returned by `CarProfileRegistry.forVariant("di5.1")`.
 * Passenger = `Fission` (same as plain Generic — the framework path
 * works on Di5.1), but cluster is tightened to **conservative
 * (empty)** vs plain Generic's `{Pixel}`: claiming a pixel cluster
 * on an unprobed trim is exactly the over-grant
 * `Generic`'s KDoc warns about. Profiled L8 / L5L / L5U keep their
 * real cluster (they resolve in `ALL`, never here).
 */
internal val GENERIC_DI51 = GENERIC_PROFILE.copy(
    dilinkFamily = DilinkFamily.Di51,
    capabilities = GENERIC_PROFILE.capabilities.copy(
        passenger = PassengerTransport.Fission,
        cluster = emptySet(),
    ),
)
