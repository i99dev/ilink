package com.i99dev.ilink.display

import com.i99dev.ilink.car.profiles.CarProfileRegistry
import com.i99dev.ilink.pkg.DishareTransport
import org.junit.Test
import kotlin.test.assertEquals

/**
 * End-to-end matrix for [DisplayLaunchPlanner] — the single
 * display-control decision. Pins, for every
 * (target × generation × content-kind × expectCluster) the planner
 * must keep stable:
 *
 *  * the Di5.0 regression fix — a `Display(4)` foreign launch on
 *    ANY Di5.0 car (L5 *and* Song PLUS) reaches the driver
 *    (`cluster_tr`), NOT the co-pilot;
 *  * mini-app own content reaches any display via `SurfaceCreate`;
 *  * Di5.1 stays am-start with the cluster permission gate intact;
 *  * Generic / role-only-no-id falls back to the default display.
 */
class DisplayLaunchPlannerTest {

    private val l5 = CarProfileRegistry.forVariant("l5")
    private val songPlus = CarProfileRegistry.forVariant("song_plus")
    private val l8 = CarProfileRegistry.forVariant("l8")
    private val l5u = CarProfileRegistry.forVariant("l5u")
    private val generic = CarProfileRegistry.forVariant(null)

    // Di5.0 classifier reports every BYD slot `passenger` (0 = ivi).
    private val di50Roles: (Int) -> String = { id -> if (id == 0) "ivi" else "passenger" }

    // L8/L5U XDJA topology: 0 ivi, 2 passenger, 5 cluster.
    private val di51Roles: (Int) -> String = { id ->
        when (id) {
            0 -> "ivi"
            2 -> "passenger"
            5 -> "cluster"
            else -> "unknown"
        }
    }

    private fun foreign(
        profile: com.i99dev.ilink.car.profiles.CarProfile,
        target: DisplayLaunchPlanner.Target,
        roles: (Int) -> String,
        expectCluster: Boolean = false,
    ) = DisplayLaunchPlanner.plan(
        target,
        DisplayLaunchPlanner.ContentKind.ForeignApp,
        profile,
        roles,
        expectCluster,
    )

    // ── Di5.0 foreign app: displayId is the surface discriminator ────

    // Di5.0: FSE/passenger = DiShare mirror; CLUSTER = ShellLaunch
    // (am-start on the cluster display via the shell bridge — the
    // working Shaheen RouteEngine.launchCluster mechanism; DiShare
    // quickShare does not paint the cluster on this ROM).
    @Test fun `L5 foreign Display 2 to FSE (DiShare), 3 and 4 to cluster ShellLaunch`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.Dishare(DishareTransport.DEVICE_FSE),
            foreign(l5, DisplayLaunchPlanner.Target.Display(2), di50Roles),
        )
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.ShellLaunch(
                DishareTransport.DISPLAY_ID_CLUSTER_CENTER,
            ),
            foreign(l5, DisplayLaunchPlanner.Target.Display(3), di50Roles),
        )
        // The regression assertion: the driver card reaches the
        // driver display (4), not the co-pilot.
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.ShellLaunch(
                DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT,
            ),
            foreign(l5, DisplayLaunchPlanner.Target.Display(4), di50Roles),
        )
    }

    @Test fun `Song PLUS behaves identically to L5 (cluster ShellLaunch, FSE DiShare)`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.ShellLaunch(
                DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT,
            ),
            foreign(songPlus, DisplayLaunchPlanner.Target.Display(4), di50Roles),
        )
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.Dishare(DishareTransport.DEVICE_FSE),
            foreign(songPlus, DisplayLaunchPlanner.Target.Display(2), di50Roles),
        )
    }

    @Test fun `L5 role-only resolves role-first`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.Dishare(DishareTransport.DEVICE_FSE),
            foreign(l5, DisplayLaunchPlanner.Target.Role("passenger"), di50Roles),
        )
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.ShellLaunch(
                DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT,
            ),
            foreign(l5, DisplayLaunchPlanner.Target.Role("cluster"), di50Roles),
        )
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.ShellLaunch(
                DishareTransport.DISPLAY_ID_CLUSTER_CENTER,
            ),
            foreign(l5, DisplayLaunchPlanner.Target.Role("cluster", small = true), di50Roles),
        )
    }

    @Test fun `L5 foreign Display 0 is IviLocal`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.IviLocal,
            foreign(l5, DisplayLaunchPlanner.Target.Display(0), di50Roles),
        )
    }

    // ── Own content → SurfaceCreate, any display, both generations ───

    @Test fun `own content reaches any display via SurfaceCreate`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.SurfaceCreate(4),
            DisplayLaunchPlanner.plan(
                DisplayLaunchPlanner.Target.Display(4),
                DisplayLaunchPlanner.ContentKind.OwnContent,
                l5,
                di50Roles,
            ),
        )
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.SurfaceCreate(5),
            DisplayLaunchPlanner.plan(
                DisplayLaunchPlanner.Target.Display(5),
                DisplayLaunchPlanner.ContentKind.OwnContent,
                l8,
                di51Roles,
            ),
        )
    }

    // ── Di5.1 / XDJA: am-start + cluster permission gate ─────────────

    @Test fun `L8 foreign Display 5 cluster, expectCluster true, is AmStart`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.AmStart(5),
            foreign(l8, DisplayLaunchPlanner.Target.Display(5), di51Roles, expectCluster = true),
        )
    }

    @Test fun `L8 foreign Display 2 passenger is AmStart`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.AmStart(2),
            foreign(l8, DisplayLaunchPlanner.Target.Display(2), di51Roles),
        )
    }

    @Test fun `L8 bare launch onto a cluster display is requires_cluster_op`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.Unreachable("requires_cluster_op"),
            foreign(l8, DisplayLaunchPlanner.Target.Display(5), di51Roles),
        )
    }

    @Test fun `L8 launch_cluster onto a passenger display is expected_cluster_got`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.Unreachable("expected_cluster_got_passenger"),
            foreign(
                l8,
                DisplayLaunchPlanner.Target.Display(2),
                di51Roles,
                expectCluster = true,
            ),
        )
    }

    @Test fun `L5U is Di5_1 - foreign cluster Display 5 is AmStart (like L8)`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.AmStart(5),
            foreign(l5u, DisplayLaunchPlanner.Target.Display(5), di51Roles, expectCluster = true),
        )
    }

    // ── Generic / role-only-no-id → default display ──────────────────

    @Test fun `Generic role-only foreign launch falls to IviLocal`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.IviLocal,
            foreign(generic, DisplayLaunchPlanner.Target.Role("passenger"), di51Roles),
        )
    }

    @Test fun `Generic Display foreign launch is am-start (Fission)`() {
        assertEquals(
            DisplayLaunchPlanner.LaunchPlan.AmStart(2),
            foreign(generic, DisplayLaunchPlanner.Target.Display(2), di51Roles),
        )
    }
}
