package com.i99dev.ilink.car.profiles

import com.i99dev.ilink.display.DisplayClassifier
import com.i99dev.ilink.display.DisplayRoles
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse

/**
 * Lock-in test for the DiLink 5.0 vs 5.1 trim-capability branching.
 *
 * Why this file exists: the entire secondary-display dispatch path
 * (DiShare cast on L5/Song PLUS [Di5.0/BYD] vs framework am-start
 * on L8/L5L/L5U [Di5.1/XDJA]) hinges
 * on TWO fields per trim — `capabilities.passenger` and
 * `capabilities.cluster`. A future edit to a trim definition that
 * silently flips one of those bits will quietly route every passenger
 * launch on that trim through the wrong transport with no visible
 * crash (the launch just goes to the wrong display, or to no display).
 *
 * Pinning the matrix here means a regression shows up as a one-line
 * test diff in PR review, NOT as a customer-visible bug.
 *
 * Authoritative branch site (a `passenger == DishareQuickShare`
 * comparison) lives in `DisplayLaunchPlanner` (the Di5.0↔Di5.1
 * fork). If you change that fork, update the comments below.
 */
class CarProfileBranchingTest {

    // ── DiLink 5.1 trims: passenger = Fission, cluster has Pixel ──────────

    @Test fun `Leopard8 is DiLink 5_1 - Fission passenger + Pixel cluster`() {
        // L8 is the headline 5.1 reference trim — the one the cluster
        // surface push-to-cluster regression of 2026-05-14 was diagnosed on.
        val p = CarProfileRegistry.forVariant("l8")
        assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
        assertTrue(ClusterCapability.Pixel in p.capabilities.cluster)
    }

    @Test fun `Leopard5_Lidar is DiLink 5_1 - Fission passenger + Pixel cluster`() {
        // L5L is the dual-cap odd-one-out: same 5.1 framework as L8
        // (Fission + Pixel) but also retains the L5 icon-tray API.
        val p = CarProfileRegistry.forVariant("l5l")
        assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
        assertTrue(ClusterCapability.Pixel in p.capabilities.cluster)
        assertTrue(ClusterCapability.Icons in p.capabilities.cluster)
    }

    // ── DiLink 5.0 trims: passenger = DishareQuickShare ──────────────────
    //
    // L5 (Flagship + Navigator) + Song PLUS use BYD's
    // `com.byd.dishare` priv-app and its quickShare op (op=8) — a
    // single binder transaction that commits a cast to a named
    // device tag without synthetic input. (L5U is NOT here — it is
    // Di5.1/XDJA and behaves like L8/L5L; see its test in the 5.1
    // section. The `com.byd.dishare` path is BYD-container only.)

    @Test fun `Leopard5 is DiLink 5_0 - DishareQuickShare passenger + cluster reachable via DiShare`() {
        val p = CarProfileRegistry.forVariant("l5")
        assertEquals(PassengerTransport.DishareQuickShare, p.capabilities.passenger)
        assertFalse(
            ClusterCapability.Pixel in p.capabilities.cluster,
            "L5 cluster must NOT have Pixel — framework `setLaunchDisplayId` is dropped; reach via DishareQuickShare instead",
        )
        assertTrue(ClusterCapability.DishareQuickShare in p.capabilities.cluster)
        assertTrue(ClusterCapability.Icons in p.capabilities.cluster)
    }

    @Test fun `Leopard5_Ultra is DiLink 5_1 XDJA - Fission passenger + Pixel cluster (like L5L, NOT L5)`() {
        // CORRECTION (operator field-attested): L5U is Di5.1/XDJA and
        // behaves like L8/L5L, NOT like the Di5.0/BYD L5 base. The
        // prior `DishareQuickShare` config was an unverified value
        // inherited from pre-refactor code and was the lone
        // Di5.1-but-DiShare profile (the smell). Mirrors L5L: Fission
        // + {Pixel, Icons}, NOT DishareQuickShare.
        val p = CarProfileRegistry.forVariant("l5u")
        assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
        assertTrue(ClusterCapability.Pixel in p.capabilities.cluster)
        assertTrue(ClusterCapability.Icons in p.capabilities.cluster)
        assertFalse(
            ClusterCapability.DishareQuickShare in p.capabilities.cluster,
            "L5U is XDJA/Di5.1 — the BYD com.byd.dishare path does not apply",
        )
    }

    @Test fun `Song PLUS is a normal Di5_0 car - identical capabilities to L5`() {
        // Field-attested correction 2026-05-17: the foreign-app driver
        // launch works on EVERY Di5.0 DiLink car, Song PLUS included.
        // The prior `cluster=emptySet()` / `showCluster=false` was an
        // inherited conservative guess (a read-only scan can't launch),
        // the same class of error as the L5U mis-tag. Song PLUS now
        // mirrors L5 exactly: DishareQuickShare passenger +
        // {DishareQuickShare, Icons} cluster (NOT Pixel — framework
        // setLaunchDisplayId is dropped on the BYD container).
        val p = CarProfileRegistry.forVariant("song_plus")
        assertEquals(PassengerTransport.DishareQuickShare, p.capabilities.passenger)
        assertFalse(
            ClusterCapability.Pixel in p.capabilities.cluster,
            "Song PLUS is BYD-container — cluster reached via DiShare, not Pixel",
        )
        assertTrue(ClusterCapability.DishareQuickShare in p.capabilities.cluster)
        assertTrue(ClusterCapability.Icons in p.capabilities.cluster)
    }

    @Test fun `Song PLUS Smart Drive is base Song PLUS behaviour but EV`() {
        // code40d=330 BEV variant (live 2026-06-12). Same Di5.0 /
        // BYD-container / DiShare behaviour as base song_plus
        // (DI50_BYD_DISHARE) — the ONLY delta is powertrain Ev (vs the
        // base's Phev), which drives mini-app battery-only data UX.
        val p = CarProfileRegistry.forVariant("song_plus_sd")
        val base = CarProfileRegistry.forVariant("song_plus")
        assertEquals(PassengerTransport.DishareQuickShare, p.capabilities.passenger)
        assertTrue(ClusterCapability.DishareQuickShare in p.capabilities.cluster)
        assertEquals(Powertrain.Ev, p.powertrain)
        assertFalse(
            base.powertrain == p.powertrain,
            "song_plus_sd must differ from base Song PLUS on powertrain (Ev vs Phev)",
        )
        // Everything else matches the base archetype exactly.
        assertEquals(base.capabilities.passenger, p.capabilities.passenger)
        assertEquals(base.capabilities.cluster, p.capabilities.cluster)
        assertEquals(base.displays.clusterDisplayId, p.displays.clusterDisplayId)
    }

    @Test fun `Sealion 06 EV is the Di5_0 DiShare archetype but EV`() {
        // code40d=201 BEV (live 2026-06-19). Same Di5.0 / BYD-container /
        // DiShare behaviour as the Sealion 6 DM-i (DI50_BYD_DISHARE) — the
        // ONLY delta is powertrain Ev (vs the DM-i's Phev). Mirrors the
        // song_plus_sd ↔ song_plus relationship.
        val p = CarProfileRegistry.forVariant("sealion6_ev")
        val dmi = CarProfileRegistry.forVariant("sealion6_dmi")
        assertEquals(DilinkFamily.Di50, p.dilinkFamily)
        assertEquals(PassengerTransport.DishareQuickShare, p.capabilities.passenger)
        assertTrue(ClusterCapability.DishareQuickShare in p.capabilities.cluster)
        assertEquals(Powertrain.Ev, p.powertrain)
        assertFalse(
            dmi.powertrain == p.powertrain,
            "sealion6_ev must differ from the DM-i on powertrain (Ev vs Phev)",
        )
        // Everything else matches the DM-i (and the shared archetype).
        assertEquals(dmi.capabilities.passenger, p.capabilities.passenger)
        assertEquals(dmi.capabilities.cluster, p.capabilities.cluster)
        assertEquals(dmi.displays.clusterDisplayId, p.displays.clusterDisplayId)
        assertEquals(dmi.displays.hiddenDisplayIds, p.displays.hiddenDisplayIds)
    }

    @Test fun `Leopard 5 Navigator is identical to base L5 (Di5_0 DiShare)`() {
        // code40d=0 Di5.0 PHEV (live 2026-06-20). Pure-identity copy of the
        // base L5 archetype (DI50_BYD_DISHARE) — a distinct row only so the
        // trim surfaces by name. NO behaviour/display delta vs base l5.
        val nav = CarProfileRegistry.forVariant("l5_nav")
        val base = CarProfileRegistry.forVariant("l5")
        assertEquals(DilinkFamily.Di50, nav.dilinkFamily)
        assertEquals(PassengerTransport.DishareQuickShare, nav.capabilities.passenger)
        assertEquals("Leopard 5 Navigator", nav.familyName)
        // Everything behavioural matches base L5 exactly.
        assertEquals(base.dilinkFamily, nav.dilinkFamily)
        assertEquals(base.powertrain, nav.powertrain)
        assertEquals(base.capabilities.passenger, nav.capabilities.passenger)
        assertEquals(base.capabilities.cluster, nav.capabilities.cluster)
        assertEquals(base.displays.clusterDisplayId, nav.displays.clusterDisplayId)
        assertEquals(base.displays.hiddenDisplayIds, nav.displays.hiddenDisplayIds)
    }

    // ── Generic fallback: permissive defaults ─────────────────────────────

    @Test fun `Generic fallback is permissive (Fission + Pixel) by design`() {
        // Both an unknown variantId and a null variantId fall through
        // to GENERIC. The contract (see Generic.kt KDoc) is PERMISSIVE,
        // not restrictive — assume secondary surfaces are reachable
        // until a real probe says otherwise. The DisplayClassifier has
        // the final say at runtime; an over-eager grant here surfaces
        // as a "no cap delivered" message instead of a crash.
        //
        // CRITICAL: Generic must NOT be DishareQuickShare — that path
        // synthetically injects 2-finger gestures, which is invasive
        // and would fire on unprofiled trims with no working dishare
        // service. Fission is the safe assumption (standard Android
        // API; silently fails if the trim doesn't support it).
        val unknown = CarProfileRegistry.forVariant("totally-fake")
        val nullV = CarProfileRegistry.forVariant(null)
        for (p in listOf(unknown, nullV)) {
            assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
            assertTrue(
                ClusterCapability.Pixel in p.capabilities.cluster,
                "Generic cluster must include Pixel; saw ${p.capabilities.cluster}",
            )
        }
    }

    // ── Di5.0↔Di5.1 fork contract — mirror the planner's predicate ────────

    @Test fun `DiShare predicate fires exactly on DishareQuickShare trims`() {
        // This mirrors the single-line fork `DisplayLaunchPlanner`
        // makes (`capabilities.passenger == DishareQuickShare`). The
        // fork BROADENED in the runtime-DiLink-fallback change: an
        // unknown car whose only signal is the `"di5.0"` token now
        // also resolves to DiShare. The block below is updated to
        // match — the assertion is the contract, NOT the code.
        fun shouldUseDishareFor(variantId: String?): Boolean {
            val profile = CarProfileRegistry.forVariant(variantId)
            return profile.capabilities.passenger == PassengerTransport.DishareQuickShare
        }

        // 5.0 / BYD container → DiShare
        assertTrue(shouldUseDishareFor("l5"))
        assertTrue(shouldUseDishareFor("song_plus"))

        // 5.1 / XDJA → standard am-start (NOT DiShare). L5U is here
        // (operator-attested XDJA), NOT in the 5.0 group.
        assertFalse(shouldUseDishareFor("l8"))
        assertFalse(shouldUseDishareFor("l5l"))
        assertFalse(shouldUseDishareFor("l5u"))

        // Runtime DiLink fallback (unknown variant, generation token
        // only): di5.0 → DiShare (fixes silent Di5.0 cast failure);
        // di5.1 → Fission, NOT DiShare.
        assertTrue(shouldUseDishareFor("di5.0"))
        assertFalse(shouldUseDishareFor("di5.1"))

        // Truly unknown (no token at all) / null → permissive
        // Generic, NOT DiShare.
        assertFalse(shouldUseDishareFor(null))
        assertFalse(shouldUseDishareFor("invented-variant"))
    }

    // ── Runtime DiLink fallback shape ─────────────────────────────────────

    @Test fun `unknown car resolves by DiLink token with conservative cluster`() {
        // The Dart detector puts the `ro.vehicle.type` generation
        // token at the head of the model-id chain when the variant is
        // unknown, so it arrives at forVariant() as a plain string.
        // forVariant must hand back a generation-correct profile with
        // a CONSERVATIVE (empty) cluster — we never claim an unprobed
        // cluster surface on an unidentified trim.
        val di50 = CarProfileRegistry.forVariant("di5.0")
        assertEquals(DilinkFamily.Di50, di50.dilinkFamily)
        assertEquals(PassengerTransport.DishareQuickShare, di50.capabilities.passenger)
        assertTrue(
            di50.capabilities.cluster.isEmpty(),
            "unknown Di5.0 must NOT claim a cluster surface; saw ${di50.capabilities.cluster}",
        )

        val di51 = CarProfileRegistry.forVariant("di5.1")
        assertEquals(DilinkFamily.Di51, di51.dilinkFamily)
        assertEquals(PassengerTransport.Fission, di51.capabilities.passenger)
        assertTrue(
            di51.capabilities.cluster.isEmpty(),
            "unknown Di5.1 must NOT claim a cluster surface; saw ${di51.capabilities.cluster}",
        )

        // Profiled trims are unaffected — they resolve in ALL and
        // keep their real cluster (regression guard for the new tier).
        assertTrue(ClusterCapability.Pixel in CarProfileRegistry.forVariant("l8").capabilities.cluster)
        assertEquals(
            PassengerTransport.DishareQuickShare,
            CarProfileRegistry.forVariant("l5").capabilities.passenger,
        )
    }

    // ── Generation-aware nameplate stubs (forChain) ──────────────────────
    //
    // A known-but-unprofiled nameplate (Tang, Sealion, Han, …) arrives
    // as a chain `[stubVariant, dilinkFamily]`. Resolving by the HEAD
    // alone (forVariant) gives the permissive Fission Generic — the
    // WRONG transport for a Di5.0 BYD-container car (am-start creates an
    // invisible task; only DiShare casts). forChain folds the
    // generation token onto GENERIC_DI50/51 so the stub gets the
    // correct transport + container topology while keeping the
    // conservative empty cluster.

    @Test fun `Di5_0 nameplate stub resolves to DiShare transport + BYD container topology`() {
        // e.g. a real BYD Tang: chain ["tang","di5.0"]. Must NOT be the
        // Fission Generic — that silently breaks passenger/cluster casts.
        val p = CarProfileRegistry.forChain(listOf("tang", "di5.0"))
        assertEquals(
            PassengerTransport.DishareQuickShare, p.capabilities.passenger,
            "a Di5.0 nameplate stub must use the DiShare transport, not Fission",
        )
        assertEquals(DilinkFamily.Di50, p.dilinkFamily)
        // Friendly name is still precise (rung-2 stub name preserved).
        assertEquals("BYD Tang", p.familyName)
        // Inherits the BYD-container display topology (clusterDisplayId=4,
        // Small Panel hidden, tap-remap 4->2) from GENERIC_DI50.
        assertEquals(4, p.displays.clusterDisplayId)
        assertTrue(3 in p.displays.hiddenDisplayIds)
        assertEquals(2, p.displays.inputDisplayFor(4))
        // Caps stay conservative (no cluster claim on an unprobed trim).
        assertTrue(
            p.capabilities.cluster.isEmpty(),
            "an unprofiled stub must not claim a cluster surface; saw ${p.capabilities.cluster}",
        )
    }

    @Test fun `Di5_1 nameplate stub resolves to Fission transport`() {
        // e.g. a Di5.1 Seal: chain ["seal","di5.1"] → Fission (framework),
        // NOT DiShare. Generation-correct, conservative cluster.
        val p = CarProfileRegistry.forChain(listOf("seal", "di5.1"))
        assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
        assertEquals(DilinkFamily.Di51, p.dilinkFamily)
        assertEquals("BYD Seal", p.familyName)
        assertTrue(p.capabilities.cluster.isEmpty())
    }

    @Test fun `nameplate stub with no generation token stays plain Generic (backward compat)`() {
        // Single-id forVariant (capability seeds / Settings override) has
        // no token, so the stub stays generation-agnostic — unchanged.
        val p = CarProfileRegistry.forVariant("tang")
        assertEquals(PassengerTransport.Fission, p.capabilities.passenger)
        assertEquals(DilinkFamily.Unknown, p.dilinkFamily)
        assertEquals("BYD Tang", p.familyName)
    }

    @Test fun `forChain head precedence — a profiled trim wins over the token`() {
        // A fully-profiled head must resolve to its ALL entry even when a
        // generation token trails it; the token only matters for stubs.
        val p = CarProfileRegistry.forChain(listOf("l5", "di5.0"))
        assertEquals("l5", p.variantId)
        assertTrue(ClusterCapability.Icons in p.capabilities.cluster)
    }

    // ── Registry stability — every profile must classify cleanly ──────────

    // ── XDJA cluster layer routing (Di5.1) ────────────────────────────────
    //
    // The XDJA fission topology stacks three displays (3 = mirror of
    // 5, 4 = sibling `_0` overlay, 5 = driver eyeline). Two semantic
    // roles need separate layers: APP target = 5 (the only picker-
    // visible cluster id) and CURSOR overlay = 4 (a foreign-uid
    // `TYPE_APPLICATION_OVERLAY` on display 5 loses to the app's own
    // surface in the XDJA compositor, so the cursor was invisible —
    // verified on 192.168.4.72 / L8). Input lands on 3 (the focusable
    // window's display); zoom renders on 5 (visible layer).
    //
    // Lock-in: a future profile edit that flips cursor back onto the
    // app layer would silently re-break "I can't see the cursor".

    @Test fun `Di5_1 XDJA cluster — cursor + tap both on projection layer 3`() {
        for (variant in listOf("l8", "l5l", "l5u")) {
            val p = CarProfileRegistry.forVariant(variant)
            // App layer = 5 for the picker: 3 and 4 are hidden, so 5
            // is the only cluster surface the operator can pick.
            assertTrue(
                3 in p.displays.hiddenDisplayIds && 4 in p.displays.hiddenDisplayIds,
                "$variant must hide 3 and 4 (only 5 is a valid app target); " +
                    "saw ${p.displays.hiddenDisplayIds}",
            )
            assertFalse(
                5 in p.displays.hiddenDisplayIds,
                "$variant must NOT hide 5 (the picker-visible Driver layer)",
            )
            // Cursor + tap MUST share a single source display so the
            // pointer and click visually co-locate. Display 3 is the
            // XDJA "ScreenProjection" source — its content is projected
            // onto the driver-visible 5, so cursor + tap both at the
            // SAME (x, y) on 3 surface at the SAME projected (x', y')
            // on 5. Iteration history:
            //   * Cursor on 5 + tap on 3: cursor visible, click landed
            //     at a different visible position than the pointer
            //     (projection isn't 1:1 pixel-aligned).
            //   * Cursor on 4: invisible (layer 4 is "flickery" per
            //     L8 probe).
            //   * Cursor on 5 + tap on 5: cursor visible but tap did
            //     not reach the app (input window lives on 3 on L8).
            //   * Cursor on 3 + tap on 3: cursor invisible (operator-
            //     attested — XDJA does NOT project foreign-uid
            //     overlays from 3 onto 5; only the app's own surface
            //     rides the projection).
            //   * Cursor on 5 + tap on 3 with identity coord scaling:
            //     both expressed in the source 1920×720 touchableRegion
            //     space, so the cursor's `LayoutParams.x/y` on display
            //     5 and the tap's `input -d 3 X Y` use the same units
            //     — aligned visually when display 5 and display 3 are
            //     both 1920×720 (true on L8 per the topology probe).
            assertEquals(
                5, p.displays.cursorDisplayFor(3),
                "$variant cursor on a display-3 request must route to 5 " +
                    "(the only foreign-uid-visible layer); tap stays on 3",
            )
            assertEquals(
                5, p.displays.cursorDisplayFor(5),
                "$variant cursor on a display-5 request stays on 5 (identity)",
            )
            // Input on a 5-addressed request still lands on 3 (the
            // focusable window's display, mirror of 5). Kept in
            // the profile for the picker's `inputSourceDisplayId`
            // snapshot field even though `handleClusterInputInject`
            // currently uses the raw resolver display (always 3).
            assertEquals(3, p.displays.inputDisplayFor(5))
            // Zoom stays on 5 (rendered on the visible layer).
            assertEquals(5, p.displays.zoomDisplayFor(3))
        }
    }

    @Test fun `Di5_0 BYD container — Driver Dashboard on 4, cursor + tap routed to working surfaces`() {
        // L5/Song PLUS topology (verified on-car 2026-05-20):
        //   * Driver Dashboard (4) is the picker-visible cluster —
        //     DiShare's `cluster_tr` mirrors source-display pixels to
        //     it. NEVER hidden.
        //   * Small Panel (3) is a sibling of 4 (both `mDisplayId
        //     ToMirror=0`), NOT a parent layer, so an overlay painted
        //     on 3 is invisible to the driver looking at 4. Hidden
        //     from the picker (it's a silent-failing cast target on
        //     its own — operator field reports), but no longer used
        //     for the cursor overlay.
        //   * Cursor remap: identity. The cluster-pad cursor lives on
        //     layer 4 directly; TYPE_APPLICATION_OVERLAY z-stacks
        //     above the DiShare cast frames on the same layer.
        //   * Input remap: 4 → 2. Display 4 has no touchable window
        //     (`InputDispatcher: Dropping event because there is no
        //     touchable window … in display 4`); the cast app's
        //     focusable Activity lives on the DiShare source display
        //     (2 — FSE Co-pilot), so taps must inject there.
        //
        // Lock-ins:
        //   * Re-routing the cursor back to 3 → invisible to driver
        //     (cursor-on-3 was the pre-2026-05-20 theory; verified
        //     wrong by the L5 dumpsys + on-car operator report).
        //   * Re-removing inputRemap[4→2] → tap drops silently on
        //     display 4 with no touchable window.
        //   * Unhiding 3 → re-exposes the silent-failing tile.
        for (variant in listOf("l5", "song_plus")) {
            val p = CarProfileRegistry.forVariant(variant)
            assertTrue(
                3 in p.displays.hiddenDisplayIds,
                "$variant must hide Small Panel (3) — saw " +
                    "${p.displays.hiddenDisplayIds}",
            )
            assertFalse(
                4 in p.displays.hiddenDisplayIds,
                "$variant must NOT hide Driver Dashboard (4)",
            )
            assertEquals(
                4, p.displays.cursorDisplayFor(4),
                "$variant cursor for a Driver-Dashboard (4) request " +
                    "must stay on 4 — displays 3 and 4 are siblings, " +
                    "so an overlay on 3 is invisible to the driver",
            )
            assertEquals(
                2, p.displays.inputDisplayFor(4),
                "$variant tap for a Driver-Dashboard (4) request " +
                    "must route to display 2 — display 4 carries no " +
                    "touchable window; the cast app's input window " +
                    "lives on the DiShare source display (2)",
            )
            assertEquals(
                4, p.displays.clusterDisplayId,
                "$variant must pin clusterDisplayId=4 so the per-" +
                    "display override classifies Driver Dashboard as " +
                    "`cluster` (owner-package layer flattens to passenger)",
            )
        }
    }

    @Test fun `Di5_1 fission (no cluster) does NOT remap cursor away from its display`() {
        // L7 / HAN L: single driver surface on 4. There's no sibling
        // overlay layer to escape to, so cursor stays on 4 (identity).
        // Lock-in: a copy-paste of the XDJA `3 to 4, 5 to 4` mapping
        // onto these trims would break their already-working cursor.
        //
        // L7 is back here after the 3.5.0-b cluster-on-display-3 attempt
        // broke the app on a real L7 (it relocated MainActivity onto
        // display 3 → no-focusable-task home loop). See Leopard7.kt for
        // the full root cause; L7 stays no-cluster until the cluster is
        // a SEPARATE surface that doesn't move the main task.
        for (variant in listOf("l7", "han_l")) {
            val p = CarProfileRegistry.forVariant(variant)
            assertEquals(4, p.displays.cursorDisplayFor(4))
        }
    }

    @Test fun `Leopard7 stays no-cluster (3_5_0-b cluster attempt reverted)`() {
        // Regression guard: re-enabling the L7 cluster as
        // DI51_XDJA_CLUSTER (clusterDisplayId=3 / showCluster=true)
        // shipped in 3.5.0-b and hung the app on a real L7 — the XDJA
        // archetype pulled MainActivity onto the cluster display. Keep
        // L7 no-cluster until a separate-surface cluster path is built
        // and verified on-car.
        val p = CarProfileRegistry.forVariant("l7")
        assertFalse(p.displays.showCluster, "L7 must NOT expose a cluster yet")
        assertTrue(
            p.capabilities.cluster.isEmpty(),
            "L7 cluster set must be empty until the separate-surface path lands; saw ${p.capabilities.cluster}",
        )
        assertEquals(null, p.displays.clusterDisplayId)

        // 2026-06-12: "Driver Cluster" (display 4) is exposed again, but
        // now cast via OUR VirtualDisplay (pkg.projectToCluster), NOT
        // move-task — the move-task path onto the XDJA OWN_CONTENT_ONLY
        // display is what hung the head unit. Guard the safe shape:
        //   * displays 2 (idle FSE) + 3 (BYD gauge) stay HIDDEN,
        //   * display 4 is NOT hidden (it's the projection cluster target),
        //   * no XDJA owner-role map — so the cluster-ROLE AmStart launch
        //     path is never engaged; only the explicit projection fork
        //     (display_drop_picker `_runLaunch`) casts to display 4.
        assertTrue(
            2 in p.displays.hiddenDisplayIds && 3 in p.displays.hiddenDisplayIds,
            "L7 must hide XDJA displays 2,3; saw ${p.displays.hiddenDisplayIds}",
        )
        assertFalse(
            4 in p.displays.hiddenDisplayIds,
            "L7 display 4 must be EXPOSED as the projection cluster target",
        )
        assertEquals("Driver Cluster", p.displays.overrideLabels[4])
        assertTrue(
            p.displays.secondaryDisplayOwners.isEmpty(),
            "L7 must map no XDJA owner role (cluster-ROLE AmStart path must " +
                "stay disengaged); saw ${p.displays.secondaryDisplayOwners}",
        )
    }

    @Test fun `every registered profile has a defined passenger transport`() {
        // Guards against a `PassengerTransport` enum value being added
        // (e.g. a future "Hypervisor" transport) and a trim definition
        // forgetting to opt into one of {None, Fission, DishareQuickShare}.
        // Kotlin enums are exhaustive — this test just confirms every
        // profile actually picks one and the registry returns it.
        for (profile in CarProfileRegistry.knownProfilesForTesting()) {
            // A non-null PassengerTransport is what the wire contract
            // assumes. Type system already enforces non-null; this
            // exists to make the assumption explicit in the test
            // suite (if a future refactor makes it nullable, this
            // test fails loudly instead of NPE-ing in production).
            @Suppress("USELESS_IS_CHECK")
            assertTrue(profile.capabilities.passenger is PassengerTransport)
        }
    }

    // ── Leopard 8 drone-kit ROM (l8_dk) — pinned passenger on display 2 ──

    @Test fun `l8_dk pins display 2 as passenger and 3+4 as cluster`() {
        // The drone-kit L8 ROM: all secondaries are XDJA-owned fission_bg
        // (display 2 = FSE, 3+4 = split cluster, no display 5). Display 2
        // shares its owner AND its "fission" name with the cluster, so a
        // per-id passenger pin is the only thing that can classify it
        // correctly — owner-package + name layers would call it cluster.
        val p = CarProfileRegistry.forVariant("l8_dk")
        assertEquals(DilinkFamily.Di51, p.dilinkFamily)
        // EXPERIMENTAL: passenger via DiShare quickShare (am-start
        // re-homes off the XDJA OWN_CONTENT_ONLY FSE; this ROM ships the
        // Di5.0 DiShareApiService, so route the FSE through it).
        assertEquals(PassengerTransport.DishareQuickShare, p.capabilities.passenger)
        assertTrue(ClusterCapability.Pixel in p.capabilities.cluster)
        assertEquals(2, p.displays.passengerDisplayId)
        // 3/4 are the REAL cluster here — must NOT be hidden (the base l8
        // hides them as shadows of display 5, which this ROM lacks).
        assertFalse(3 in p.displays.hiddenDisplayIds)
        assertFalse(4 in p.displays.hiddenDisplayIds)
        // No display-5 remaps (display 5 does not exist on this ROM).
        assertTrue(p.displays.cursorRemap.isEmpty())
        assertTrue(p.displays.inputRemap.isEmpty())

        // Classifier end-to-end: display 2 (XDJA-owned, "fission" name)
        // pins to passenger; 3/4 (same owner) classify cluster.
        val xdja = "com.xdja.containerservice"
        fun roleOf(id: Int) = DisplayClassifier.classify(
            displayId = id,
            name = "fission_bg_XDJAScreenProjection",
            widthPx = 1920,
            heightPx = 720,
            marker = "fission",
            profile = p.displays,
            ownerPackageName = xdja,
        ).role
        assertEquals(DisplayRoles.PASSENGER, roleOf(2))
        assertEquals(DisplayRoles.CLUSTER, roleOf(3))
        assertEquals(DisplayRoles.CLUSTER, roleOf(4))
    }

    @Test fun `standard l8 is untouched by the drone-kit fix`() {
        // The passengerDisplayId pin defaults to null everywhere else, so
        // the base l8 keeps its exact 5-surface behaviour (3/4 hidden as
        // shadows, no passenger pin). Regression guard.
        val p = CarProfileRegistry.forVariant("l8")
        assertEquals(null, p.displays.passengerDisplayId)
        assertTrue(3 in p.displays.hiddenDisplayIds && 4 in p.displays.hiddenDisplayIds)
    }
}
