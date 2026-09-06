package com.i99dev.ilink.pkg

import com.i99dev.ilink.car.profiles.CarProfileRegistry
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins the Di5.0 / BYD-container device-tag map. Drift here would
 * route a passenger cast to the cluster (or vice-versa) with no
 * compile-time signal, so the wire contract lives here.
 *
 * The map is container-uniform: every Di5.0 / `DishareQuickShare`
 * car (L5, Song PLUS, …) resolves identically — `2=fse`,
 * `3=cluster_c`, `4=cluster_tr`, role-first preferred. Trims with no
 * DiShare path (Di5.1 / XDJA: L8, L5L, L5U; Generic) return null and
 * the planner uses am-start.
 */
class DeviceTagResolverTest {

    private val l5 = CarProfileRegistry.forVariant("l5")
    private val songPlus = CarProfileRegistry.forVariant("song_plus")

    // ── Role-first (preferred over numeric displayId) ────────────────

    @Test fun `passenger role resolves to FSE tag`() {
        assertEquals(
            DishareTransport.DEVICE_FSE,
            DeviceTagResolver.tagFor("passenger", null, l5),
        )
    }

    @Test fun `cluster role resolves to driver-dashboard tag (top-right)`() {
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_TOPRIGHT,
            DeviceTagResolver.tagFor("cluster", null, l5),
        )
    }

    @Test fun `cluster_small role resolves to centre cluster tag`() {
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_CENTER,
            DeviceTagResolver.tagFor("cluster_small", null, l5),
        )
    }

    @Test fun `role wins over displayId when both are present`() {
        // Caller intent over physical mapping: an explicit passenger
        // role with the cluster's numeric id still resolves passenger.
        // Keeps SDK callers stable across trims that renumber displays.
        assertEquals(
            DishareTransport.DEVICE_FSE,
            DeviceTagResolver.tagFor(
                "passenger",
                DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT,
                l5,
            ),
        )
    }

    // ── Numeric fallback (no role hint) — the uniform Di5.0 layout ───

    @Test fun `displayId 2 resolves to FSE tag`() {
        assertEquals(
            DishareTransport.DEVICE_FSE,
            DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_FSE, l5),
        )
    }

    @Test fun `displayId 3 resolves to centre cluster tag`() {
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_CENTER,
            DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_CLUSTER_CENTER, l5),
        )
    }

    @Test fun `displayId 4 resolves to driver-dashboard (top-right) tag`() {
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_TOPRIGHT,
            DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT, l5),
        )
    }

    @Test fun `displayId 0 (IVI) resolves to null - never DiShare-cast`() {
        assertNull(DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_IVI, l5))
    }

    @Test fun `unknown displayId resolves to null`() {
        assertNull(DeviceTagResolver.tagFor(null, 99, l5))
    }

    @Test fun `null role and null displayId resolves to null`() {
        assertNull(DeviceTagResolver.tagFor(null, null, l5))
    }

    // ── Song PLUS is a normal Di5.0 car — identical to L5 ────────────

    @Test fun `Song PLUS resolves identically to L5 (driver works on all Di5_0)`() {
        // Field-attested correction: Song PLUS has the same
        // DiShare-reachable cluster as L5 (cluster now
        // {DishareQuickShare,Icons}); the prior emptySet was a wrong
        // inherited guess. The Di5.0 layout is a container constant.
        assertEquals(
            DishareTransport.DEVICE_FSE,
            DeviceTagResolver.tagFor("passenger", null, songPlus),
        )
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_TOPRIGHT,
            DeviceTagResolver.tagFor("cluster", null, songPlus),
        )
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_CENTER,
            DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_CLUSTER_CENTER, songPlus),
        )
        assertEquals(
            DishareTransport.DEVICE_CLUSTER_TOPRIGHT,
            DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT, songPlus),
        )
    }

    // ── Di5.1 / XDJA + Generic — no DiShare path, resolver self-safe ─

    @Test fun `Di5_1 (L8, L5L, L5U) and Generic resolve every request to null`() {
        // L8/L5L/L5U = Fission + Pixel (XDJA/am-start); Generic =
        // Fission + Pixel. None has a DiShare path → null for every
        // request (the planner takes the am-start branch instead).
        for (p in listOf(
            CarProfileRegistry.forVariant("l8"),
            CarProfileRegistry.forVariant("l5l"),
            CarProfileRegistry.forVariant("l5u"),
            CarProfileRegistry.forVariant(null),
        )) {
            assertNull(DeviceTagResolver.tagFor("passenger", null, p))
            assertNull(DeviceTagResolver.tagFor("cluster", null, p))
            assertNull(DeviceTagResolver.tagFor(null, DishareTransport.DISPLAY_ID_FSE, p))
            assertNull(
                DeviceTagResolver.tagFor(
                    null,
                    DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT,
                    p,
                ),
            )
        }
    }
}
