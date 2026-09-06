package com.i99dev.ilink.car.profiles.definitions


/**
 * Song Pro (宋Pro) — Di5.0 / BYD container. A **normal Di5.0 BYD trim**:
 * same container, same DiShare path, same display topology as Song PLUS /
 * Leopard 5. Pure identity over [DI50_BYD_DISHARE] — NO behavioural delta
 * (transport, displays, capabilities all inherited from the archetype).
 *
 * Detection is nameplate-only. Live scan 2026-06-17 (adb 127.0.0.1:5999):
 *   * `persist.sys.byd.default_name = 宋Pro`
 *   * `ro.vehicle.type = DiLink100_7.0UI` → dilinkFamily **di5.0**
 *   * `vehicle_40d_code = 0`, `model_variant.model = unknown`
 *   * `energytype = 2` (PHEV — live elec range 15 km + fuel range 708 km)
 *   * displays 0 (IVI 1920×1080) + 2/3/4 (`com.byd.containerservice`
 *     VIRTUAL 1280×480, OWN_CONTENT_ONLY) — same topology shape as
 *     L5 / Song PLUS (resolution delta only; cluster daemon-locked,
 *     DiShare-reachable).
 *
 * Because code40d=0 and there's no carType/modelVariant token, the
 * `(carType, vehicleId)` and integer paths in `model_detector.dart` all
 * miss — the default name is the only signal. The 宋PLUS substring match
 * does NOT catch 宋Pro, so without a dedicated detector row this car fell
 * through to GENERIC_DI50 and showed as an unidentified "Generic BYD
 * Di5.0" car. See `byd_model_detector.dart` `_resolveByDefaultName`.
 *
 * On-car verification of the DiShare opcodes remains the shared Track-B
 * item for all Di5.0 trims (RE-derived); the #127 launch-outcome decoder
 * surfaces an honest failure if a given ROM's DiShare service differs.
 */
internal val SONG_PRO_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "song_pro",
    familyName = "Song Pro",
)
