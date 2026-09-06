package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.Powertrain

/**
 * Song PLUS Smart Drive — Di5.0 / BYD container, behaviourally the
 * same as the base [SONG_PLUS_PROFILE] (the [DI50_BYD_DISHARE]
 * archetype) but a PURE-EV (BEV) powertrain.
 *
 * Live ground truth 2026-06-12 (adb 127.0.0.1:5999):
 *   * `default_name = 宋PLUS`, `ro.vehicle.type = Di5.0_5.0UI` (Di5.0),
 *     `ro.product.model = "DiLink5.0 For BYD AUTO"`.
 *   * `vehicle_40d_code = 330` — NEW. The base Song PLUS is 243; both
 *     share `outsw 23.1.83`. `model_variant.model = "unknown"` (Song
 *     PLUS exposes no token), so detection keys on the code40d
 *     integer — see `byd_model_detector.dart:_resolveModel` (tier-2
 *     vehicleId switch, alongside 243).
 *   * Container `com.byd.containerservice` + `com.byd.dishare`;
 *     displays 0(ivi)/2/3/4 = `(shared_)fission_bg_
 *     XDJAScreenProjection`, owner `com.byd.containerservice` —
 *     byte-identical to the L5 / Song PLUS DI50_BYD_DISHARE layout
 *     (display 2 hosts `com.byd.naviauto` meter).
 *   * `persist.sys.energytype = 1` → pure-EV (the PHEV trims L7 / L5U
 *     report 2). This is the ONLY behavioural delta vs base Song PLUS.
 *
 * Archetype: [DI50_BYD_DISHARE] — DishareQuickShare passenger +
 * {DishareQuickShare, Icons} cluster, `clusterDisplayId = 4`, exactly
 * like base Song PLUS. The sole `.copy` override is `powertrain = Ev`,
 * which drives mini-app battery-only (vs battery+fuel) data UX.
 *
 * // VERIFY on-car: confirm BEV — no fuel gauge / `dicare_record`
 * //   `hev_mileage` column absent — before relying on the Ev UX.
 * //   energytype=1→EV is inferred from the PHEV-trims-are-2 pattern.
 */
internal val SONG_PLUS_SD_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "song_plus_sd",
    familyName = "Song PLUS Smart Drive",
    powertrain = Powertrain.Ev,
)
