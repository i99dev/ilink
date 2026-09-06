package com.i99dev.ilink.display

import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.display.ClusterCastPolicy.CastMechanism
import com.i99dev.ilink.display.ClusterCastPolicy.ClusterCastClass
import org.junit.Test
import kotlin.test.assertEquals

/**
 * Pins the centralised cast policy: cast-class detection from runtime display
 * facts, and the (family × cast-class) → mechanism matrix. The load-bearing
 * cases:
 *   * L8 / L5U cluster (own XDJA group) → am-start;
 *   * L7 cluster (group-0 fission OR ScreenProjection name) → project (no hang);
 *   * Di5.0 cluster (L5 / Song / Sealion) → shell-launch;
 *   * **unknown Di5.1 cluster → project** (the anti-hang fail-safe — the whole
 *     point: a profile-less Di5.1 car must never move-task onto its cluster).
 */
class ClusterCastPolicyTest {

    // ── cast-class detection ────────────────────────────────────────
    @Test fun `Di50 cluster is always BYD-container (DiShare never paints it)`() {
        assertEquals(
            ClusterCastClass.BydContainerCluster,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di50,
                displayGroupId = 1, iviGroupId = 0, // group signal irrelevant on Di5.0
                name = "cluster_tr",
                profileSaysProject = false,
            ),
        )
    }

    @Test fun `Di51 cluster on its own display group is launchable XDJA (L8 display 5)`() {
        assertEquals(
            ClusterCastClass.LaunchableXdja,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di51,
                displayGroupId = 2, iviGroupId = 0,
                name = "XDJA cluster",
                profileSaysProject = false,
            ),
        )
    }

    @Test fun `Di51 cluster sharing the IVI group is a group-0 fission hazard (L7)`() {
        assertEquals(
            ClusterCastClass.Group0FissionHazard,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di51,
                displayGroupId = 0, iviGroupId = 0, // shares IVI group 0
                name = "driver",
                profileSaysProject = false,
            ),
        )
    }

    @Test fun `Di51 ScreenProjection-bg name is a hazard even without a group signal`() {
        assertEquals(
            ClusterCastClass.Group0FissionHazard,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di51,
                displayGroupId = null, iviGroupId = null,
                name = "shared_fission_bg_XDJAScreenProjection_0",
                profileSaysProject = false,
            ),
        )
    }

    @Test fun `profile castsViaProjection hint forces hazard (transitional L7 flag)`() {
        assertEquals(
            ClusterCastClass.Group0FissionHazard,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di51,
                displayGroupId = 2, iviGroupId = 0, // would be launchable…
                name = "driver",
                profileSaysProject = true, // …but the profile says project
            ),
        )
    }

    @Test fun `Di51 cluster with no group signal is UnknownCluster (will be projected)`() {
        assertEquals(
            ClusterCastClass.UnknownCluster,
            ClusterCastPolicy.classifyCastClass(
                role = DisplayRoles.CLUSTER,
                family = DilinkFamily.Di51,
                displayGroupId = null, iviGroupId = null,
                name = "driver",
                profileSaysProject = false,
            ),
        )
    }

    @Test fun `non-cluster roles short-circuit to NotCluster`() {
        for (r in listOf(DisplayRoles.IVI, DisplayRoles.PASSENGER, DisplayRoles.UNKNOWN)) {
            assertEquals(
                ClusterCastClass.NotCluster,
                ClusterCastPolicy.classifyCastClass(
                    role = r, family = DilinkFamily.Di51,
                    displayGroupId = 0, iviGroupId = 0, name = "x",
                    profileSaysProject = false,
                ),
                "role $r",
            )
        }
    }

    // ── (family × cast-class) → mechanism matrix ─────────────────────
    private fun mech(
        role: String,
        family: DilinkFamily,
        passenger: PassengerTransport,
        castClass: ClusterCastClass,
    ) = ClusterCastPolicy.mechanismFor(role, family, passenger, castClass)

    @Test fun `launchable XDJA cluster → am-start (L8 L5U)`() {
        assertEquals(
            CastMechanism.AmStart,
            mech(DisplayRoles.CLUSTER, DilinkFamily.Di51, PassengerTransport.Fission, ClusterCastClass.LaunchableXdja),
        )
    }

    @Test fun `group-0 fission cluster → project (L7, no hang)`() {
        assertEquals(
            CastMechanism.Project,
            mech(DisplayRoles.CLUSTER, DilinkFamily.Di51, PassengerTransport.Fission, ClusterCastClass.Group0FissionHazard),
        )
    }

    @Test fun `UNKNOWN Di51 cluster → project (anti-hang fail-safe)`() {
        assertEquals(
            CastMechanism.Project,
            mech(DisplayRoles.CLUSTER, DilinkFamily.Di51, PassengerTransport.Fission, ClusterCastClass.UnknownCluster),
        )
    }

    @Test fun `Di50 cluster → shell-launch (L5 Song Sealion)`() {
        assertEquals(
            CastMechanism.ShellLaunch,
            mech(DisplayRoles.CLUSTER, DilinkFamily.Di50, PassengerTransport.DishareQuickShare, ClusterCastClass.BydContainerCluster),
        )
    }

    @Test fun `Di50 passenger DiShare and Di51 passenger am-start`() {
        assertEquals(
            CastMechanism.Dishare,
            mech(DisplayRoles.PASSENGER, DilinkFamily.Di50, PassengerTransport.DishareQuickShare, ClusterCastClass.NotCluster),
        )
        assertEquals(
            CastMechanism.AmStart,
            mech(DisplayRoles.PASSENGER, DilinkFamily.Di51, PassengerTransport.Fission, ClusterCastClass.NotCluster),
        )
    }

    @Test fun `no passenger transport → unreachable`() {
        assertEquals(
            CastMechanism.Unreachable,
            mech(DisplayRoles.PASSENGER, DilinkFamily.Di51, PassengerTransport.None, ClusterCastClass.NotCluster),
        )
    }

    @Test fun `IVI → ivi-local regardless of family`() {
        assertEquals(
            CastMechanism.IviLocal,
            mech(DisplayRoles.IVI, DilinkFamily.Di50, PassengerTransport.DishareQuickShare, ClusterCastClass.NotCluster),
        )
    }
}
