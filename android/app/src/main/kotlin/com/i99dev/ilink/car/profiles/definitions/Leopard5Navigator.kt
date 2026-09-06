package com.i99dev.ilink.car.profiles.definitions

/**
 * BYD Leopard 5 Navigator (豹5 领航) — Di5.0 / BYD container,
 * FangChengBao, PHEV. Behaviourally the [DI50_BYD_DISHARE] archetype —
 * same container, same DiShare passenger+cluster path, same 0/2/3/4
 * BYD-container display topology as the base [LEOPARD5_PROFILE] / Song
 * PLUS. Pure identity (variantId / familyName) only; NO display or
 * behaviour delta vs base L5 — a distinct row only so the trim surfaces
 * by name (the per-trim pattern used by [SEALION6_DMI_PROFILE]).
 *
 * Live ground truth 2026-06-20 (adb 127.0.0.1:5999):
 *   * `model_variant.model = fcbsf`, `default_name = 豹5`,
 *     `ro.vehicle.type = Di5.0_5.0UI`, `ro.product.model =
 *     "DiLink5.0 For BYD AUTO"`.
 *   * `vehicle_40d_code = 0` (UNSET). The base L5 keys on code40d=153
 *     and L5 Ultra on 304; this unit exposes neither, so detection keys
 *     on `carType FCBSF + code40d=0 + Di5.0` — Di5.0-gated so a future
 *     Di5.1 FCBSF with an unset code can never grab this DiShare
 *     profile. See the FCBSF branch in `byd_model_detector.dart`.
 *   * Container `com.byd.containerservice` + `com.byd.dishare`; displays
 *     0(ivi)/2/3/4 = `(shared_)fission_bg_XDJAScreenProjection` owned by
 *     `com.byd.containerservice` — byte-identical to base L5. The display
 *     NAMES contain "XDJAScreenProjection" but the OWNER is the BYD
 *     container, NOT XDJA (don't name-substring match).
 *   * `persist.sys.energytype = 2` → PHEV (the archetype default — no
 *     `.copy(powertrain=...)` needed).
 *   * SDK 32 (Android 12), arm64-v8a.
 */
internal val LEOPARD5_NAVIGATOR_PROFILE = DI50_BYD_DISHARE.copy(
    variantId = "l5_nav",
    familyName = "Leopard 5 Navigator",
)
