package com.i99dev.ilink.car.profiles.definitions


/**
 * Qin L (秦L) — Di5.0 / BYD container. A **normal Di5.0 BYD trim**:
 * same container, same DiShare path, same display topology as Song Pro /
 * Song PLUS / Leopard 5. Pure identity over [DI50_BYD_DISHARE] — NO
 * behavioural delta (transport, displays, capabilities all inherited
 * from the archetype).
 *
 * Detection is nameplate-only. Live scan 2026-06-17 (adb 127.0.0.1:5999):
 *   * `persist.sys.byd.default_name = 秦L`
 *   * `ro.vehicle.type = Di5.0_5.0UI` → dilinkFamily **di5.0**
 *   * `vehicle_40d_code = 0`, `model_variant.model = unknown`
 *   * `energytype = 2` (PHEV — Qin L DM-i)
 *   * `com.byd.containerservice` `fission_bg_XDJAScreenProjection` virtual
 *     display — same BYD-container topology as Song Pro / L5.
 *
 * code40d=0 and no carType/modelVariant token, so the `(carType,vehicleId)`
 * and integer paths in `model_detector.dart` all miss — the default name is
 * the only signal. Without a dedicated row this car fell through to
 * GENERIC_DI50 and showed as an unidentified "Generic BYD Di5.0" car. See
 * `byd_model_detector.dart` `_resolveByDefaultName`.
 *
 * On-car verification of the DiShare opcodes remains the shared Track-B
 * item for all Di5.0 trims (RE-derived); the #127 launch-outcome decoder
 * surfaces an honest failure if a given ROM's DiShare service differs.
 */
internal val QIN_L_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "qin_l",
    familyName = "Qin L",
)
