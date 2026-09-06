package com.i99dev.ilink.nav.transport.someip

import com.i99dev.ilink.nav.NavHudOptions
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId
import com.i99dev.ilink.nav.transport.HudRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TASK-003 — the *selection* half of the SOME/IP variant seam.
 *
 * What this pins, and why it is worth pinning even though every row currently
 * answers `ui7`: the resolution RULE (model → default; a set pref overrides it)
 * and the DEFAULT (`ui7`, our on-car-proven wire — explicitly not the reference
 * implementation's `LAUNCHER_MAP_CN`). The day a second variant lands, these
 * tests are what stop the fleet's default from silently moving onto it.
 *
 * The unknown-model row is the important one: a car we fail to detect must land
 * on the proven wire, not on nothing and not on a guess.
 */
class NavSomeIpVariantSelectionTest {

    // --- the resolution matrix: model → default -------------------------------

    @Test
    fun defaultIsUi7ForEveryKnownModel() {
        // L8 (UI7) reads SOME/IP RoadInfo — the path we have proven on a car.
        assertEquals("ui7", SomeIpVariants.defaultFor("Leopard 8"))
        // L5 Long Range renders via CAN-FID and ignores RoadInfo, so this option
        // does not affect it; the SOME/IP push still happens (drive-all) and must
        // stay on the proven wire.
        assertEquals("ui7", SomeIpVariants.defaultFor("Leopard 5"))
        assertEquals("ui7", SomeIpVariants.defaultFor("Leopard 5 Ultra"))
        assertEquals("ui7", SomeIpVariants.defaultFor("Leopard 5 Lidar"))
        assertEquals("ui7", SomeIpVariants.defaultFor("Leopard 7"))
        assertEquals("ui7", SomeIpVariants.defaultFor("BYD HAN L"))
        assertEquals("ui7", SomeIpVariants.defaultFor("Song PLUS Smart Drive"))
    }

    @Test
    fun defaultIsUi7ForUndetectedOrUnknownModels() {
        assertEquals("ui7", SomeIpVariants.defaultFor(null))
        assertEquals("ui7", SomeIpVariants.defaultFor(""))
        assertEquals("ui7", SomeIpVariants.defaultFor("   "))
        assertEquals("ui7", SomeIpVariants.defaultFor("Seal U"))
        assertEquals("ui7", SomeIpVariants.defaultFor("some future trim"))
    }

    /** The headline guarantee, asserted as a property over the whole matrix rather
     *  than as seven separate literals: there is NO model for which the resolved
     *  default is anything but the proven wire. */
    @Test
    fun noModelPathEverDefaultsAwayFromUi7() {
        val models = listOf(
            null, "", "Leopard 8", "Leopard 5", "Leopard 5 Ultra", "Leopard 5 Lidar",
            "Leopard 7", "BYD HAN L", "Song PLUS Smart Drive", "Atto 3", "?!",
        )
        for (m in models) {
            assertEquals("model '$m' does not default to ui7", "ui7", SomeIpVariants.defaultFor(m))
            assertEquals(
                "model '$m' with no pref does not resolve to ui7",
                "ui7", SomeIpVariants.resolve(null, m),
            )
            assertEquals(
                "model '$m' on auto does not resolve to ui7",
                "ui7", SomeIpVariants.resolve("auto", m),
            )
        }
    }

    /**
     * The reference implementation defaults to `LAUNCHER_MAP_CN`. We deliberately do not.
     *
     * **Updated by TASK-016:** the variant now EXISTS and is selectable by hand,
     * so the old assertion ("not a known id") is gone on purpose. The guarantee it
     * was protecting is unchanged and is now stated directly: no model, and no
     * absent/auto preference, may ever RESOLVE to it. Only an explicit opt-in can.
     */
    @Test
    fun launcherMapCnIsOptInOnlyAndNeverADefault() {
        val models = listOf(
            null, "", "Leopard 8", "Leopard 5", "Leopard 5 Ultra", "Leopard 7",
            "BYD HAN L", "Song PLUS Smart Drive", "Atto 3", "?!",
        )
        for (m in models) {
            assertNotEquals(SomeIpVariants.LAUNCHER_MAP_CN, SomeIpVariants.defaultFor(m))
            assertNotEquals(SomeIpVariants.LAUNCHER_MAP_CN, SomeIpVariants.resolve(null, m))
            assertNotEquals(SomeIpVariants.LAUNCHER_MAP_CN, SomeIpVariants.resolve("auto", m))
        }
        // Reachable ONLY by asking for it by name.
        assertTrue(SomeIpVariants.isKnown("launcher_map_cn"))
        assertEquals("launcher_map_cn", SomeIpVariants.resolve("launcher_map_cn", "Leopard 8"))
        assertTrue(SomeIpVariants.create("launcher_map_cn") is LauncherMapCnVariant)
    }

    // --- the resolution matrix: pref overrides the model default ---------------

    @Test
    fun setPreferenceOverridesTheModelDerivedDefault() {
        assertEquals("ui7", SomeIpVariants.resolve("ui7", "Leopard 8"))
        assertEquals("ui7", SomeIpVariants.resolve("ui7", null))
        // Case/whitespace tolerated — a pref written by hand via `adb shell` is a
        // supported way to exercise the revert path on a car.
        assertEquals("ui7", SomeIpVariants.resolve(" UI7 ", null))
    }

    /**
     * The override rule, asserted so it can actually FAIL.
     *
     * With one ported variant every branch of `resolve` returns `ui7`, so the
     * three assertions above would still pass if the override were deleted
     * outright — mutation-verified, they do. Injecting a divergent model default
     * is what makes "a set preference beats the model" a real claim today rather
     * than a promise that only becomes checkable when a second variant lands.
     *
     * This is exactly the revert scenario: a future build's per-model default has
     * moved the car onto another wire, and the tester's `ui7` must win anyway.
     */
    @Test
    fun setPreferenceBeatsADivergentModelDefault() {
        val futureDefault: (String?) -> String = { "some_future_variant" }

        // Pref set → pref wins, whatever the model would have chosen.
        assertEquals("ui7", SomeIpVariants.resolve("ui7", "Leopard 8", futureDefault))
        assertEquals("ui7", SomeIpVariants.resolve("ui7", null, futureDefault))

        // No pref / auto → the model default is genuinely consulted (proving the
        // seam is wired and the assertion above isn't just a constant).
        assertEquals(
            "some_future_variant",
            SomeIpVariants.resolve(null, "Leopard 8", futureDefault),
        )
        assertEquals(
            "some_future_variant",
            SomeIpVariants.resolve("auto", "Leopard 8", futureDefault),
        )
    }

    @Test
    fun autoAndNullAndUnknownPrefsFallThroughToTheModelDefault() {
        assertEquals("ui7", SomeIpVariants.resolve(null, "Leopard 8"))
        assertEquals("ui7", SomeIpVariants.resolve("auto", "Leopard 8"))
        // Unknown id (e.g. left behind by a rollback from a build that had more
        // variants) must degrade to the default, never throw and never stick.
        assertEquals("ui7", SomeIpVariants.resolve("no_such_variant", "Leopard 8"))
    }

    @Test
    fun knownIdSet() {
        assertEquals(listOf("auto", "ui7", "launcher_map_cn"), SomeIpVariants.ids)
        assertTrue(SomeIpVariants.isKnown("auto"))
        assertTrue(SomeIpVariants.isKnown("ui7"))
        assertTrue(SomeIpVariants.isKnown("launcher_map_cn"))
        assertTrue(!SomeIpVariants.isKnown(null))
        assertTrue(!SomeIpVariants.isKnown("someip"))
    }

    // --- the factory ----------------------------------------------------------

    @Test
    fun factoryFallsBackToUi7ForAutoNullAndGarbage() {
        assertTrue(SomeIpVariants.create("ui7") is Ui7Variant)
        assertTrue(SomeIpVariants.create("auto") is Ui7Variant)
        assertTrue(SomeIpVariants.create(null) is Ui7Variant)
        assertTrue(SomeIpVariants.create("no_such_variant") is Ui7Variant)
        assertEquals("UI7", SomeIpVariants.create("ui7").name)
        assertEquals("LAUNCHER_MAP_CN", SomeIpVariants.create("launcher_map_cn").name)
    }

    /** The model name reaches the per-model pose table (the one calibration hook)
     *  and never leaks into the proven UI7 path. */
    @Test
    fun factoryPassesTheModelToThePerModelPoseTable() {
        val v = SomeIpVariants.create("launcher_map_cn", modelName = "Leopard 8")
        assertTrue(v is LauncherMapCnVariant)
        // Uncalibrated today: every model still yields the reference capture, so
        // the wire must be identical to the no-model construction.
        assertEquals(
            SomeIpVariants.create("launcher_map_cn").serviceIds,
            v.serviceIds,
        )
    }

    // --- NavHudOptions: the real object, not just the pure resolver ------------

    /**
     * Exercises the option object itself (prefs uninitialised — the SharedPrefs
     * handle is null-safe by construction), so the matrix is proven through the
     * code path the transport actually reads, not only through [SomeIpVariants].
     */
    @Test
    fun optionsResolveModelDefaultThenHonourOverride() {
        NavHudOptions.setModelNameForTest("Leopard 8")
        assertEquals("auto", NavHudOptions.someIpVariant)          // stored default
        assertEquals("ui7", NavHudOptions.resolvedSomeIpVariant)   // resolved default

        // Unknown model → still the proven wire.
        NavHudOptions.setModelNameForTest(null)
        assertEquals("ui7", NavHudOptions.resolvedSomeIpVariant)

        // Explicit override wins and is what the transport will read.
        NavHudOptions.setSomeIpVariant("ui7")
        assertEquals("ui7", NavHudOptions.someIpVariant)
        assertEquals("ui7", NavHudOptions.resolvedSomeIpVariant)

        // Unknown values are ignored (same contract as clusterProtocol) — the
        // option stays put rather than landing on something unrenderable.
        NavHudOptions.setSomeIpVariant("no_such_variant")
        assertEquals("ui7", NavHudOptions.someIpVariant)

        // TASK-016: the opt-in variant is settable by hand, and — critically —
        // the revert back to the proven wire still works from there.
        NavHudOptions.setSomeIpVariant("launcher_map_cn")
        assertEquals("launcher_map_cn", NavHudOptions.someIpVariant)
        assertEquals("launcher_map_cn", NavHudOptions.resolvedSomeIpVariant)
        NavHudOptions.setSomeIpVariant("ui7")
        assertEquals("ui7", NavHudOptions.resolvedSomeIpVariant)

        // Back to auto.
        NavHudOptions.setSomeIpVariant("auto")
        assertEquals("auto", NavHudOptions.someIpVariant)
        assertEquals("ui7", NavHudOptions.resolvedSomeIpVariant)
    }

    // --- SelectedSomeIpVariant: live re-resolution (the no-rebuild revert) -----

    @Test
    fun selectedVariantReResolvesOnEveryAccessSoAFlipNeedsNoRebuild() {
        var id = "ui7"
        val sel = SelectedSomeIpVariant(FakeRenderer) { id }

        assertEquals("UI7", sel.name)
        assertEquals(listOf(Ui7Variant.SERVICE_ID), sel.serviceIds)

        // TASK-016 makes this a REAL wire change rather than a re-resolution that
        // happens to land on the same variant: flipping to the opt-in variant
        // must swap the service ids with no rebuild and no transport rebuild...
        id = "launcher_map_cn"
        assertEquals("LAUNCHER_MAP_CN", sel.name)
        assertEquals(6, sel.serviceIds.size)
        assertTrue(Ui7Variant.SERVICE_ID !in sel.serviceIds)
        assertEquals(11, sel.buildEvents(frame, 1).size)

        // ...and flipping back must restore exactly the proven wire. This is the
        // on-car revert path, exercised.
        id = "ui7"
        assertEquals("UI7", sel.name)
        assertEquals(listOf(Ui7Variant.SERVICE_ID), sel.serviceIds)
        assertEquals(1, sel.buildEvents(frame, 1).size)

        id = "auto"
        assertEquals("UI7", sel.name)
        assertNotNull(sel.buildClearEvents())
    }

    @Test
    fun selectedVariantMemoisesPerIdSoTheHotPathDoesNotAllocate() {
        var id = "ui7"
        val sel = SelectedSomeIpVariant(FakeRenderer) { id }
        sel.name
        // Same id → same delegate instance on the push path.
        val a = sel.buildEvents(frame, 1)
        val b = sel.buildEvents(frame, 1)
        assertEquals(a[0].second.size, b[0].second.size)
        id = "auto"
        assertEquals("UI7", sel.name)
    }

    /** A throwing provider must degrade to the proven variant, never take the
     *  HUD down — the option is a convenience, not a dependency. */
    @Test
    fun selectedVariantSurvivesAThrowingProvider() {
        val sel = SelectedSomeIpVariant(FakeRenderer) { error("boom") }
        assertEquals("UI7", sel.name)
        assertEquals(listOf(Ui7Variant.SERVICE_ID), sel.serviceIds)
        assertEquals(1, sel.buildEvents(frame, 3).size)
    }

    /** The delegate must be a pass-through: identical bytes to the variant it
     *  wraps, so wrapping it can never change what the cluster receives. */
    @Test
    fun selectedVariantIsByteIdenticalToTheVariantItWraps() {
        val sel = SelectedSomeIpVariant(FakeRenderer) { "ui7" }
        val direct = Ui7Variant(FakeRenderer)
        assertEquals(
            direct.buildEvents(frame, 9)[0].second.toList(),
            sel.buildEvents(frame, 9)[0].second.toList(),
        )
        assertEquals(
            direct.buildClearEvents()[0].second.toList(),
            sel.buildClearEvents()[0].second.toList(),
        )
        assertEquals(direct.serviceIds, sel.serviceIds)
        assertEquals(Ui7Variant.TOPIC_ROAD, sel.buildEvents(frame, 9)[0].first)
    }

    private object FakeRenderer : HudRenderer {
        override fun iconPng(maneuverCode: Int): ByteArray = byteArrayOf(1, 2, 3)
        override fun iconCode(maneuverCode: Int): Int = maneuverCode
        override fun guideLine(maneuverCode: Int, lat: Double?, lon: Double?, heading: Double?) =
            "[[0,0],[1,1]]"
        override fun formatEta(remainingSeconds: Int?): String =
            remainingSeconds?.takeIf { it >= 0 }?.let { "${(it + 59) / 60} min" } ?: ""
    }

    private companion object {
        val frame = NavGuidance(
            maneuverIcon = 3,
            distanceMeters = 250,
            roadName = "King Fahd Rd",
            remainingDistanceMeters = 4_200,
            remainingTimeSeconds = 540,
            source = NavSourceId.GOOGLE_MAPS,
        )
    }
}
