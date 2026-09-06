package com.i99dev.ilink.car.profiles.definitions


/**
 * Leopard 5 Lidar — Di5.1, separate family from L5 base.
 *
 * Resolved via outsw `34.1.17` + defaultName `豹5` (the name
 * disambiguates from L8 which shares the same outsw key).
 *
 * Same XDJA topology as L8 (3 base + 4 `_0` + 5 `_1`); same
 * shadow set. No live fingerprint yet — values mirror the
 * pre-refactor `VehicleProfile.Leopard5Lidar` + `VariantCapability
 * Profile.l5l` for byte-identical behavior.
 *
 * Archetype: [DI51_XDJA_CLUSTER] — L5L IS the canonical member
 * (identity only; no behavioural delta).
 *
 * Capability evidence (from code; no live probe yet):
 *   * `cluster = {Pixel, Icons}` — has both pixel-overlay (like L8)
 *     and icons (L5-family; per legacy `isL5Family` predicate).
 *   * `passenger = Fission` — Di5.1 fission2 path works.
 */
internal val LEOPARD5_LIDAR_PROFILE = DI51_XDJA_CLUSTER.copy(
    variantId = "l5l",
    familyName = "Leopard 5 Lidar",
)
