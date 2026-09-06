package com.i99dev.ilink.car.profiles.definitions

/**
 * Leopard 7 / Ti7 (钛7) — DiLink 5.1 / XDJA, MediaTek mt6983,
 * Android 13.
 *
 * Auto-detect (drives this profile via the Dart `ModelDetector` →
 * `CarProfileRegistry`): `vehicle_40d_code = 282` → variant `l7`
 * (path-independent integer key; on the sysprop fallback
 * `model_variant.model = "qz"` uppercases to carType `"QZ"`, not an
 * FCB enum value, so resolution keys on code40d — see
 * `byd_model_detector.dart:_resolveModel`). Legacy `CarIdentity`
 * compat path also resolves via outsw `34.1.35` / `23.1.24` /
 * `34.1.15` + defaultName `钛7`.
 *
 * ── CLUSTER: stays NO-CLUSTER (cluster-enable attempt REVERTED) ──
 * Live ground truth (adb 127.0.0.1:5999, `dumpsys display` +
 * `dumpsys activity activities`) DID show an addressable XDJA
 * cluster display on L7:
 *
 *   Display 0  ivi 1920×1080                       main center IVI
 *   Display 2  fission_bg_XDJAScreenProjection      idle
 *   Display 3  shared_fission_bg_XDJAScreenProjection_0
 *              → com.byd.sr/.cluster.ClusterActivity (driver cluster)
 *   Display 4  shared_fission_bg_XDJAScreenProjection_1 (map/TBT)
 *
 * i.e. the L7 cluster is its own XDJA virtual display (3), the same
 * KIND as L8's cluster (display 5). So in principle L7 is
 * cluster-capable. BUT a first attempt to model it as
 * `DI51_XDJA_CLUSTER.copy(clusterDisplayId = 3, showCluster = true)`
 * was SHIPPED in 3.5.0-b (#230) and BROKE the app on a real L7
 * (verified 2026-06-12, same car):
 *
 *   * On boot, ilink's MAIN activity (task, `MainActivity`) was
 *     relocated from display 0 onto display 3 within ~20ms of launch
 *     (`onTaskMovedToFront … displayId=0` → `displayId=3`).
 *   * That left display 0 with `no-focusable-task`, so the launcher
 *     resumed home there; ilink + `com.byd.sr ClusterActivity`
 *     then fought over display 3 and the launcher bounced 0↔3 in a
 *     loop — a visible hang / flicker. (The detection-only build,
 *     which kept L7 no-cluster, ran fine on the exact same car.)
 *
 * Root cause: on L7 the XDJA-cluster archetype's display routing
 * pulls the host's own top activity onto the cluster display instead
 * of presenting a SEPARATE cluster surface there (the way L8's
 * display-5 path does). Until that mechanism is fixed so the cluster
 * is a separate surface and `MainActivity` stays pinned to display 0,
 * L7 stays on the safe `DI51_FISSION_NO_CLUSTER` archetype.
 *
 * Re-enabling later (TODO): present an ilink cluster surface onto
 * display 3 WITHOUT moving the main task — and re-test on a real L7
 * before shipping (do not ship the cluster path unverified again).
 *
 * Archetype: [DI51_FISSION_NO_CLUSTER] — `hiddenDisplayIds = {2}`
 * and the display-4 driver remaps come from the archetype (matches
 * HAN L). `showCluster = false` / `cluster = emptySet()`.
 */
internal val LEOPARD7_PROFILE = DI51_FISSION_NO_CLUSTER.copy(
    variantId = "l7",
    familyName = "Leopard 7",
    // ── DISPLAYS: "Driver Cluster" cast via OUR VirtualDisplay (safe) ──
    // History: exposing display 4 as a move-task target was UNSAFE — a
    // foreign app moved onto the XDJA OWN_CONTENT_ONLY fission display
    // (displayGroupId 0, mirrors the IVI) latched BYD's
    // `FissionGenerayService`, dragged iLINK's own task off display 0
    // (kill/restart loop), and hung on close. Same class as the reverted
    // cluster-role path (3.5.0→3.5.1, #230/#232).
    //
    // FIXED 2026-06-12 (verified on a real L7, adb 127.0.0.1:5999): the
    // hang was the move-task / direct-am-start ONTO the XDJA display. The
    // SAFE path is the reference mechanism — project the app via OUR OWN
    // private VirtualDisplay: ClusterActivity creates the VD and am-starts
    // the app onto THAT, so the foreign task lives in its own display
    // group and never touches group 0. Confirmed: Chrome cast to the
    // cluster, iLINK stayed on the IVI, no hang, no fission latch.
    //
    // So display 4 (the writable XDJA projection layer) is exposed again
    // as "Driver Cluster". The DISPLAYS picker routes a drop here through
    // `pkg.projectToCluster` (the VD path) — NOT move-task — keyed on the
    // XDJA projection display name (display_drop_picker.dart `_runLaunch`
    // → PackagePlatformPlugin.handleProjectCluster). Displays 2 (idle FSE)
    // and 3 (BYD gauge, com.byd.sr) stay HIDDEN. secondaryDisplayOwners
    // stays empty so the cluster-ROLE launch path (DisplayLaunchPlanner
    // AmStart) is NOT engaged — only the explicit projection fork casts
    // here.
    displays = DI51_FISSION_NO_CLUSTER.displays.copy(
        secondaryDisplayOwners = emptyMap(),
        hiddenDisplayIds = setOf(2, 3),
        overrideLabels = mapOf(4 to "Driver Cluster"),
        // Display 4 casts via our own VirtualDisplay (the safe reference
        // path), so it must NOT be dimmed "cluster-vendor-locked" and the
        // drop picker must route it through pkg.projectToCluster, not
        // launchCluster/move-task. See [DisplayProfile.projectionCastDisplayIds].
        projectionCastDisplayIds = setOf(4),
    ),
)
