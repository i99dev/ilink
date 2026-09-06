package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.DisplayProfile
import com.i99dev.ilink.car.profiles.PassengerTransport

/**
 * F-series — legacy `5f` variant.
 *
 * VariantId `5f` was originally resolved through a Di5.0 +
 * `ro.vehicle.type.value == 19` heuristic. After the 2026-05-10
 * detector rewrite (BYD `ICarInfoManager` SDK as the sole
 * identity source), F-series auto-resolution depends on an SDK
 * `(carType, vehicleId)` row in `model_detector.dart:_resolveModel`
 * — to be added once a live F-series unit surfaces its
 * `getCarType()` + `getVehicleId()` values to fleet telemetry.
 * Until then this profile is reachable via the manual variant
 * override only.
 *
 * No archetype: F-series is a conservative one-off with no peer —
 * `passenger = None`, no cluster, no fission surface. Expressed as
 * a [GENERIC_PROFILE] delta (its true base): Di5.0, surfaces off.
 * No live fingerprint, no real-world validation. Mirrors
 * pre-refactor `VehicleProfile.FSeries` + `VariantCapability
 * Profile.5f`.
 */
internal val F_SERIES_PROFILE = GENERIC_PROFILE.copy(
    variantId = "5f",
    familyName = "F-series",
    dilinkFamily = DilinkFamily.Di50,
    // powertrain stays GENERIC's Unknown — no live fingerprint.
    displays = DisplayProfile(
        showCluster = false,
        showFission2 = false,
        hiddenDisplayIds = emptySet(),
        overrideLabels = emptyMap(),
        cursorRemap = emptyMap(),
        inputRemap = emptyMap(),
        zoomRemap = emptyMap(),
        secondaryDisplayOwners = emptyMap(),
    ),
    capabilities = GENERIC_PROFILE.capabilities.copy(
        passenger = PassengerTransport.None,
        cluster = emptySet(),
    ),
)
