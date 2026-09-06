package com.i99dev.ilink.car.profiles.definitions


/**
 * BYD HAN L — Di5.1, sedan flagship.
 *
 * Resolved via outsw `34.1.11`. No live fingerprint yet.
 *
 * Archetype: [DI51_FISSION_NO_CLUSTER] — same shape as L7 (no
 * cluster, fission2 passenger, hide display 2). Identity only; no
 * behavioural delta. Values mirror pre-refactor
 * `VehicleProfile.BydHanL` + `VariantCapabilityProfile.han_l`.
 */
internal val BYD_HAN_L_PROFILE = DI51_FISSION_NO_CLUSTER.copy(
    variantId = "han_l",
    familyName = "BYD HAN L",
)
