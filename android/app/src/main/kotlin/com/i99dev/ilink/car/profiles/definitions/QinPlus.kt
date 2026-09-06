package com.i99dev.ilink.car.profiles.definitions


/**
 * Qin Plus (秦Plus) — Di5.0 / BYD container. A **normal Di5.0 BYD trim**:
 * same container, same DiShare path, same display topology as Qin L /
 * Song Pro / Song PLUS / Leopard 5. Pure identity over [DI50_BYD_DISHARE]
 * — NO behavioural delta (transport, displays, capabilities inherited).
 *
 * Detection is nameplate-only. Live scan 2026-06-18 (adb 127.0.0.1:5999):
 *   * `persist.sys.byd.default_name = 秦Plus`
 *   * `ro.vehicle.type = DiLink100_7.0UI` → dilinkFamily **di5.0**
 *   * `vehicle_40d_code = 0`, `model_variant.model = unknown`
 *   * `energytype = 2` (PHEV — Qin Plus DM-i)
 *
 * code40d=0 and no carType/modelVariant token, so the `(carType,vehicleId)`
 * and integer paths in `model_detector.dart` all miss — the default name is
 * the only signal. Without a dedicated row this car fell through to
 * GENERIC_DI50 and showed as an unidentified "Generic BYD Di5.0" car. The
 * 秦L (Qin L) branch does NOT match 秦Plus (distinct tokens). See
 * `byd_model_detector.dart` `_resolveByDefaultName`.
 *
 * On-car verification of the DiShare opcodes remains the shared Track-B
 * item for all Di5.0 trims (RE-derived); the #127 launch-outcome decoder
 * surfaces an honest failure if a given ROM's DiShare service differs.
 */
internal val QIN_PLUS_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "qin_plus",
    familyName = "Qin Plus",
)
