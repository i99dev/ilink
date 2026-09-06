package com.i99dev.ilink.car.profiles.definitions

import com.i99dev.ilink.car.profiles.CapabilityProfile
import com.i99dev.ilink.car.profiles.CarProfile
import com.i99dev.ilink.car.profiles.ClusterCapability
import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.DisplayProfile
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.car.profiles.Powertrain

/**
 * Behavioural archetypes — the DiLink/container shape a group of
 * trims shares. A trim definition is `<ARCHETYPE>.copy(...)` that
 * overrides only its **identity** (`variantId`, `familyName`) and
 * any genuinely-empirical **delta** (e.g. L8's extra display labels
 * and Pixel-only cluster). The shared display topology — including
 * the gnarly cursor/input/zoom remaps — is defined ONCE per
 * archetype instead of copy-pasted across 2–3 files, which is the
 * class of drift the per-file KDocs kept correcting.
 *
 * Archetypes carry a **neutral identity placeholder** (`variantId`
 * `""`): every member overrides it, so a base is never registered
 * and never reaches `CarProfileRegistry.ALL`. The base encodes
 * *behaviour* (dilinkFamily / powertrain / displays / capabilities);
 * the member adds *identity* + deltas.
 *
 * Byte-identical guarantee: each base equals the exact field set of
 * its canonical member (A=L5L/L5U, B=L7/HAN_L, C=Song PLUS), so the
 * `.copy()` members reduce to the original `CarProfile` objects.
 * The per-variant fixture test (`knownProfilesForTesting`) pins
 * this. F-series has no peer and stays a `GENERIC_PROFILE.copy`.
 */

/**
 * **Di5.1 / XDJA container, usable pixel cluster.** XDJA-owned
 * fission topology: display 5 = driver eyeline cluster (the
 * canonical app surface; the only one the picker exposes); 3
 * (mirror of 5, hosts the actual input window) + 4 (the `_0`
 * sibling overlay layer, "flickery" per probe) are shadows
 * hidden from the picker.
 *
 * Layer assignment (3 layers, two roles needed — pin them so the
 * IVI trackpad's cursor visibly composites over the app):
 *   * **App layer = 5** ("Driver"). The only picker-visible
 *     cluster target — `pkg.launch` and `pkg.move` land here.
 *   * **Cursor overlay layer = 5 also.** A `TYPE_APPLICATION_OVERLAY`
 *     on display 5 is z-stacked above the app by Android's
 *     WindowManager (overlays sit above ordinary application
 *     windows by construction). An earlier revision routed the
 *     cursor to the sibling layer 4 on the theory that XDJA's
 *     compositor would stack the app over a foreign-uid overlay
 *     on the SAME layer — but operator-attested behaviour is
 *     that layer 4 isn't actually rendered (the probe even
 *     labels it "flickery"), so the cursor became invisible
 *     for the opposite reason. Cursor on 5 — the layer we know
 *     is rendered — with `TYPE_APPLICATION_OVERLAY` doing the
 *     z-ordering is the right answer for every Android surface,
 *     including this one.
 *   * **Input target = 3**. Touch events injected via `input -d`
 *     land on the stack that hosts the focusable activity window
 *     (display 3, mirror of 5). The mirror propagates to 5 so
 *     the driver sees the result.
 *   * **Zoom target = 5**. `wm density -d` is rendered, so it
 *     belongs on the visible layer.
 *
 * Members: Leopard 5 Lidar, Leopard 5 Ultra (identical),
 * Leopard 8 (delta: extra `overrideLabels`, Pixel-only cluster).
 */
internal val DI51_XDJA_CLUSTER = CarProfile(
    variantId = "",
    familyName = "",
    dilinkFamily = DilinkFamily.Di51,
    powertrain = Powertrain.Phev,
    displays = DisplayProfile(
        showCluster = true,
        showFission2 = true,
        hiddenDisplayIds = setOf(3, 4),
        overrideLabels = mapOf(5 to "Driver"),
        // Cursor renders on the Driver-visible layer (5). On L8 the
        // XDJA-owned cluster does NOT project foreign-uid overlays
        // from the projection-source layer (3) onto 5 — operators
        // verified an overlay on 3 is invisible. So cursor MUST be
        // on 5. Tap routes to 3 (where the app's input window
        // lives). Both end up at the SAME visible position on
        // display 5 because:
        //   * Cursor on 5: `LayoutParams.x/y` are scaled from
        //     source coord space to display 5's real pixel size
        //     ([ClusterCursorOverlay.show] queries `getRealSize`).
        //   * Tap on 3: `input -d 3 X Y` is dispatched in display 3's
        //     pixel space; XDJA projects display 3 onto display 5's
        //     visible surface with the same proportional transform.
        // Cursor + tap therefore share a proportional position on
        // the visible cluster — alignment holds at corners as well
        // as the centre. See P5 + P8 in the cluster-pad iteration
        // memory for the dead-end iterations that ruled out cursor-
        // on-3 (invisible) and identity-cursor-coords (clips at
        // edges).
        cursorRemap = mapOf(3 to 5, 5 to 5),
        inputRemap = mapOf(5 to 3),
        zoomRemap = mapOf(3 to 5),
        secondaryDisplayOwners = mapOf("com.xdja.containerservice" to "cluster"),
    ),
    capabilities = CapabilityProfile(
        universalCaps = STANDARD_UNIVERSAL_CAPS,
        passenger = PassengerTransport.Fission,
        cluster = setOf(ClusterCapability.Pixel, ClusterCapability.Icons),
    ),
)

/**
 * **Di5.1, fission passenger, NO usable cluster.** Hides display 2
 * (auxiliary); driver surface is display 4 (input from 4 delivers
 * to 2's stack). No XDJA owner-role map — name-keyword fallback.
 * Members: Leopard 7, BYD HAN L (identical).
 */
internal val DI51_FISSION_NO_CLUSTER = CarProfile(
    variantId = "",
    familyName = "",
    dilinkFamily = DilinkFamily.Di51,
    powertrain = Powertrain.Phev,
    displays = DisplayProfile(
        showCluster = false,
        showFission2 = true,
        hiddenDisplayIds = setOf(2),
        overrideLabels = mapOf(4 to "Driver"),
        cursorRemap = mapOf(4 to 4),
        inputRemap = mapOf(4 to 2),
        zoomRemap = mapOf(4 to 4),
        secondaryDisplayOwners = emptyMap(),
    ),
    capabilities = CapabilityProfile(
        universalCaps = STANDARD_UNIVERSAL_CAPS,
        passenger = PassengerTransport.Fission,
        cluster = emptySet(),
    ),
)

/**
 * **Di5.0 / BYD container, DiShare transport.** `setLaunchDisplayId`
 * is dropped on the OWN_CONTENT_ONLY virtuals, so passenger + cluster
 * are delivered via DiShare `quickShare` (display 2 = FSE co-pilot,
 * 4 = driver dashboard / `cluster_tr` — the picker-visible cluster).
 * Every fission slot classifies `passenger`; cluster reachability is
 * the DiShare device-tag's job, not a classified role.
 *
 * Layer assignment (operator-attested two-role split, matching the
 * Di5.1/XDJA archetype's pattern):
 *   * **App layer = 4** ("Driver Dashboard"). The only picker-
 *     visible cluster target; DiShare's `cluster_tr` device tag
 *     casts here. The small `cluster_c` panel at id 3 is hidden
 *     because operators dropped apps there and got silent failures
 *     (the BYD ROM's small-panel surface isn't a reliable cast
 *     target on its own).
 *   * **Cursor overlay layer = 4** (same as app). Earlier theory
 *     placed the overlay on layer 3 ("Small Panel") by analogy
 *     with Di5.1's 3→5 mirror, but the L5 dumpsys confirms
 *     displays 3 and 4 are SIBLINGS — both have
 *     `mDisplayIdToMirror=0` (the IVI). Display 3 is NOT
 *     projected onto display 4, so an overlay on 3 was invisible
 *     to the driver. The Di5.1 rule that actually generalizes is
 *     "cursor on the visible layer, TYPE_APPLICATION_OVERLAY
 *     handles z-stacking above the app." Cursor and tap therefore
 *     both target display 4 (no remap), matching the L5 sibling
 *     topology. Operator-attested 2026-05-20.
 *
 * Members: Leopard 5, Song PLUS (identical behaviour).
 */
internal val DI50_BYD_DISHARE = CarProfile(
    variantId = "",
    familyName = "",
    dilinkFamily = DilinkFamily.Di50,
    powertrain = Powertrain.Phev,
    displays = DisplayProfile(
        showCluster = true,
        showFission2 = true,
        // Small Panel is reserved for the cursor overlay layer —
        // hide it from the picker so operators don't try to cast
        // there (silent-failing tile per field reports).
        hiddenDisplayIds = setOf(3),
        overrideLabels = mapOf(
            2 to "FSE Co-pilot",
            3 to "Small Panel",
            4 to "Driver Dashboard",
        ),
        // Cursor renders on the SAME display as the cast app
        // (layer 4). Identity remap — displays 3 and 4 are XDJA
        // siblings on L5 (both mirror display 0), so an overlay
        // painted on 3 is invisible to the driver looking at 4.
        // TYPE_APPLICATION_OVERLAY's z-stacking puts the dot above
        // the DiShare-delivered cast frames on layer 4 itself.
        cursorRemap = emptyMap(),
        // Tap on cluster (4) routes to display 2. The DiShare
        // `cluster_tr` cast projects pixels FROM the source display
        // (2 — FSE Co-pilot) TO display 4; the app's actual
        // Activity + focusable input window live on display 2, and
        // display 4 carries no touchable window
        // (`InputDispatcher: Dropping event because there is no
        // touchable window … in display 4`). Operator-verified on
        // L5 2026-05-20 — `input -d 2 tap` lands cleanly on the
        // YouTube cast; `input -d 4 tap` is dropped.
        inputRemap = mapOf(4 to 2),
        zoomRemap = emptyMap(),
        secondaryDisplayOwners = mapOf("com.byd.containerservice" to "passenger"),
        // Driver Dashboard (display 4) IS the cluster on Di5.0/BYD
        // container; the surrounding fission slots are all owned by
        // the same `com.byd.containerservice` so the owner-package
        // layer alone can't tell them apart. The per-display
        // override pins layer 4 as `role=cluster` so the picker
        // surfaces it as the driver target and the cluster touchpad
        // can attach. The DiShare `cluster_tr` cast path (used by
        // `pkg.launch_cluster`) is unaffected — it keys on the
        // profile-level capability set, not the per-display role.
        clusterDisplayId = 4,
    ),
    capabilities = CapabilityProfile(
        universalCaps = STANDARD_UNIVERSAL_CAPS,
        passenger = PassengerTransport.DishareQuickShare,
        cluster = setOf(ClusterCapability.DishareQuickShare, ClusterCapability.Icons),
    ),
)
