package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.ClusterCapability

/**
 * Leopard 8 — Di5.1, MediaTek mt6983, Android 13.
 *
 * Sources:
 *   * Live collector probe: byd-fingerprint-34.1.17-20260506-074202.json
 *     (build `2511242.1` / 2025-12-07, schemaVersion 0.8.0).
 *   * `vehicle40dCode` = "155" (BYD internal code for L8).
 *   * `modelVariant` = "fcbsq" (last letter discriminates trim).
 *
 * Display topology (5 surfaces):
 *   0  ivi                              2560×1600 d=320  (Main IVI; owner=null)
 *   2  fse                              1920× 720 d=240  (FSE auxiliary; owner=null)
 *   3  fission_bg_XDJAScreenProjection  1920× 720 d=320  (XDJA-owned; mirror of 5)
 *   4  shared_fission_bg_..._0          1920× 720 d=320  (XDJA-owned; flickery)
 *   5  shared_fission_bg_..._1          1920× 720 d=320  (XDJA-owned; "Driver"
 *                                                         eyeline cluster)
 *
 * Archetype: [DI51_XDJA_CLUSTER]. Delta vs the archetype:
 *   * `overrideLabels` adds 0→"Main" + 2→"FSE" (the canonical
 *     members only label display 5).
 *   * `cluster = {Pixel}` only — L8's icons path is reachable per
 *     probe but not yet end-to-end-verified; stays Pixel-only
 *     until verified (L5L/L5U keep the archetype's {Pixel, Icons}).
 *
 * Probe provenance: `vehicle40dCode = 155`, `modelVariant = fcbsq`
 * (both retired as `CarProfile` fields — no consumer; kept here as
 * the documented trim discriminator).
 *
 * Capability evidence:
 *   * `cluster_transport.viableTransports` = ["icons", "pixel"] but only
 *     pixel is empirically wired today. Icons via autoContainer binder
 *     reachable per probe; not yet end-to-end-verified, so cluster
 *     stays as `{Pixel}` only. Promote when verified.
 *   * `dishare_transport.syntheticSwipeViable` = false → confirms
 *     `passenger = Fission`.
 *   * `body_control` v2: every channel absent. Today `bodyControl =
 *     Full` to preserve byte-identical cap output (door.set /
 *     window.set are in universalCaps); a follow-up PR splits this
 *     to remove the over-grant.
 *   * `ac_manager.bydAirconditioningServicePresent` = true →
 *     `acControl = Full`.
 *   * `byd_content_providers.dicare_record.verdict` = ok with columns
 *     including `hev_mileage` → trim is PHEV-class.
 */
internal val LEOPARD8_PROFILE = DI51_XDJA_CLUSTER.copy(
    variantId = "l8",
    familyName = "Leopard 8",
    // 0/2/5 labels — L8 surfaces a Main + FSE the canonical
    // members don't expose.
    displays = DI51_XDJA_CLUSTER.displays.copy(
        overrideLabels = mapOf(
            0 to "Main",
            2 to "FSE",
            5 to "Driver",
        ),
    ),
    // Pixel-only: L8's icons path is not yet end-to-end-verified.
    capabilities = DI51_XDJA_CLUSTER.capabilities.copy(
        cluster = setOf(ClusterCapability.Pixel),
    ),
)
