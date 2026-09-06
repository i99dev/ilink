package com.i99dev.ilink.car.profiles.definitions

/**
 * BYD Sealion 6 DM-i (海狮06DM-i) — Di5.0 / BYD container, Ocean series,
 * DM-i super-hybrid (PHEV). Behaviourally the [DI50_BYD_DISHARE]
 * archetype — same container, same DiShare passenger + cluster path,
 * Phev powertrain — exactly like Leopard 5 / base Song PLUS. Pure
 * identity (variantId / familyName) only; NO display/behaviour delta.
 *
 * Live ground truth 2026-06-13 (adb 127.0.0.1:5999, read-only scan
 * car-profiles-out/sealion6-dmi-20260613-1929):
 *   * `default_name = 海狮06DM-i`, `ro.vehicle.type = Di5.0_5.0UI`
 *     (Di5.0), `ro.product.model = "DiLink5.0 For BYD AUTO"`.
 *   * `vehicle_40d_code = 0` (UNSET) and `model_variant.model = unknown`
 *     — NEITHER the (carType,vehicleId) path NOR the vehicleId-only
 *     integer path can pin this car from the sysprop fallback. Detection
 *     therefore keys on the nameplate `default_name` (海狮06DM) — see
 *     `byd_model_detector.dart:_resolveByDefaultName` + the `defaultName`
 *     plumbed through `BydCarInfoBinder`. (Mirrors the L7 钛7 / L5 豹5
 *     default_name precedent.)
 *   * SoC `lahaina` (Snapdragon 888), Android 12 / SDK 32. Measured
 *     WebView Chromium 95 → ES-modules OK → Gate B PASSES on a Di5.0
 *     unit (the documented favorable dilink/WebView mismatch).
 *   * Container `com.byd.containerservice` + `com.byd.dishare`; NO XDJA.
 *   * `persist.sys.energytype = 2` → PHEV (DM-i). The archetype default
 *     IS Phev — no `.copy(powertrain=...)` needed (unlike the BEV
 *     [SONG_PLUS_SD_PROFILE], energytype=1).
 *
 * Displays: same as the archetype — IVI (display 0) + the DiShare
 * driver-cluster cast (showCluster) + fission slots, like L5 / Song PLUS.
 * The cluster cast WORKS on this trim (operator-confirmed 2026-06-14).
 * KNOWN ISSUE (separate, NOT a profile flag): when the user drags ilink
 * onto the driver cluster, the cast content renders BEHIND the cluster's
 * native layers (z-order / compositing). That is a cluster-cast layering
 * concern tracked outside this definition — do NOT "fix" it by disabling
 * showCluster (that removes the wanted feature).
 *
 * // VERIFY on-car: (1) PHEV — fuel + battery both present — before
 * //   relying on the Phev UX (energytype=2→PHEV is pattern-inferred).
 * // VERIFY on-car: (2) BYDAutoManager actuator surface actuates.
 */
internal val SEALION6_DMI_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "sealion6_dmi",
    familyName = "BYD Sealion 6 DM-i",
)
