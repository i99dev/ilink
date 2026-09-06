package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.ClusterCapability
import com.i99dev.ilink.car.profiles.PassengerTransport

/**
 * Leopard 8 — the DJI-drone-kit unit. Same vehicle as
 * [LEOPARD8_PROFILE] (BYD FangChengBao 豹8, Di5.1, MediaTek mt6983,
 * Android 13, PHEV) but a DIFFERENT display ROM. The drone kit itself
 * (`com.byd.droneclient`) is a pure add-on app that owns no display —
 * the only delta is the XDJA display layout.
 *
 * Live ground truth 2026-06-19 (adb 127.0.0.1:5999):
 *   * `model_variant=fcbsq` → carType `FCBSQ`; `vehicle_40d_code=0`
 *     (sysprop unset) / framework `getVehicleId()=31` (base L8 is 155);
 *     `default_name=豹8`; `ro.vehicle.type=Di5.1_5.0UI`; energytype=2.
 *   * Displays: `0` ivi, `2`/`3`/`4` = `(shared_)fission_bg_
 *     XDJAScreenProjection`, ALL owned by `com.xdja.containerservice`.
 *     NO display 5. Display 2 = FSE / co-pilot; displays 3+4 = the
 *     driver instrument cluster (`com.byd.cluster.projectionmanager`
 *     Bottom/Top split).
 *
 * Why a SEPARATE profile (not just reuse `l8`): the canonical
 * [LEOPARD8_PROFILE] assumes the 5-surface layout — FSE on a standalone
 * `owner=null` display 2, cluster on display 5, displays 3/4 hidden as
 * shadows. On THIS ROM that profile would HIDE displays 3/4 (the REAL
 * cluster) and mis-tag the XDJA-owned display 2 as cluster (owner-package
 * layer) — so the passenger never appears and the cluster vanishes. The
 * two ROMs need OPPOSITE rules for the same ids, so they cannot share one
 * profile. Keeping this separate leaves the standard L8 byte-identical.
 *
 * This profile:
 *   * `passengerDisplayId = 2` — pins the FSE as passenger (it is
 *     XDJA-owned + "fission"-named, so only an explicit id pin can beat
 *     the owner/name layers).
 *   * `secondaryDisplayOwners {xdja → cluster}` (from the archetype) →
 *     displays 3/4 classify as cluster.
 *   * `hiddenDisplayIds = {}` — 3/4 are the real cluster, NOT shadows.
 *   * cursor/input/zoom remaps EMPTY — the archetype's remaps target
 *     display 5, which does not exist on this ROM.
 *
 * // VERIFY on-car: confirm display 2 is the physical co-pilot screen and
 * //   3+4 are the driver cluster (inferred from running content +
 * //   com.byd.*.fse packages). Swap passengerDisplayId / labels if the
 * //   physical layout differs.
 */
internal val LEOPARD8_DRONEKIT_PROFILE = DI51_XDJA_CLUSTER.copy(
    variantId = "l8_dk",
    familyName = "Leopard 8",
    displays = DI51_XDJA_CLUSTER.displays.copy(
        hiddenDisplayIds = emptySet(),
        overrideLabels = mapOf(
            0 to "Main",
            2 to "FSE Co-pilot",
            3 to "Driver Cluster",
            4 to "Driver Cluster",
        ),
        passengerDisplayId = 2,
        cursorRemap = emptyMap(),
        inputRemap = emptyMap(),
        zoomRemap = emptyMap(),
    ),
    // EXPERIMENTAL (2026-06-19): am-start to the XDJA OWN_CONTENT_ONLY
    // FSE (display 2) re-homes to the head unit — proven on-car. This ROM
    // DOES ship the Di5.0-style `com.byd.dishare/.api.DiShareApiService`
    // (verified present), so route the passenger through DiShare's
    // `quickShare("fse")` binder commit instead of am-start, exactly like
    // the Di5.0 flagship (L5 / Song PLUS). DeviceTagResolver maps the FSE
    // role / display 2 → the `fse` tag. Cluster stays Pixel for now —
    // this test is the passenger path only.
    capabilities = DI51_XDJA_CLUSTER.capabilities.copy(
        passenger = PassengerTransport.DishareQuickShare,
        cluster = setOf(ClusterCapability.Pixel),
    ),
)
