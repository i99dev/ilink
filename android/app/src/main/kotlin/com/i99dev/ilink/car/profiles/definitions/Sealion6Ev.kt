package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.Powertrain

/**
 * BYD Sealion 06 EV (海狮06EV, 2025) — Di5.0 / BYD container, Ocean
 * series, **pure battery EV (BEV)**. Behaviourally the
 * [DI50_BYD_DISHARE] archetype — same container, same DiShare passenger
 * + cluster path, same 0/2/3/4 display topology as Leopard 5 / base Song
 * PLUS / the Sealion 6 DM-i. The ONLY delta vs [SEALION6_DMI_PROFILE] is
 * the powertrain: `Ev` (vs the DM-i's archetype-default `Phev`), which
 * drives mini-app battery-only (vs battery+fuel) data UX — exactly the
 * [SONG_PLUS_SD_PROFILE] relationship to base Song PLUS.
 *
 * Live ground truth 2026-06-19 (adb 127.0.0.1:5999):
 *   * `default_name = 海狮06EV`, `ro.vehicle.type = Di5.0_5.0UI` (Di5.0),
 *     `ro.product.model = "DiLink5.0 For BYD AUTO"`.
 *   * `vehicle_40d_code = 201` — NEW. (The Sealion 6 DM-i reports
 *     code40d=0 and resolves by the `海狮06DM` nameplate; this EV unit
 *     exposes a real integer, so detection keys on the code40d=201
 *     vehicleId tier — see `byd_model_detector.dart:_resolveModel`.)
 *     `model_variant.model = "unknown"`.
 *   * Container `com.byd.containerservice` + `com.byd.dishare`, displays
 *     0(ivi)/2/3/4 = `(shared_)fission_bg_XDJAScreenProjection` owned by
 *     `com.byd.containerservice` — byte-identical to the L5 / Song PLUS /
 *     Sealion 6 DM-i DI50_BYD_DISHARE layout. NO XDJA.
 *   * `persist.sys.energytype = 1` → pure-EV (the PHEV trims report 2).
 *     This is the ONLY behavioural delta vs the Sealion 6 DM-i.
 *   * SDK 32 (Android 12), arm64-v8a.
 *
 * // VERIFY on-car: confirm BEV — no fuel gauge — before relying on the
 * //   Ev UX. energytype=1→EV is the same inference used for
 * //   [SONG_PLUS_SD_PROFILE].
 */
internal val SEALION6_EV_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "sealion6_ev",
    familyName = "BYD Sealion 06 EV",
    powertrain = Powertrain.Ev,
)
