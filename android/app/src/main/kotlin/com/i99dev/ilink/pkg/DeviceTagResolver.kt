package com.i99dev.ilink.pkg

import com.i99dev.ilink.car.profiles.CarProfile
import com.i99dev.ilink.car.profiles.ClusterCapability
import com.i99dev.ilink.car.profiles.PassengerTransport

/**
 * The Di5.0 / BYD-container DiShare device-tag map: given a role or
 * numeric displayId, return the `quickShare` device tag
 * [DishareTransport.fastCast] expects — or `null` when DiShare can't
 * reach that target on this trim.
 *
 * This is a small, container-uniform lookup (the layout
 * `2=fse · 3=cluster_c · 4=cluster_tr` is the same for *every* Di5.0
 * BYD car — it's a property of the BYD container, not of any model,
 * so there is deliberately no per-model table here). It is a pure
 * component owned by [com.i99dev.ilink.display.DisplayLaunchPlanner]
 * — the planner makes the Di5.0-vs-Di5.1 / content-kind decision and
 * calls this only for the tag once it has decided DiShare applies.
 *
 * Two-input resolution:
 *   * `targetRole` — semantic intent (`"passenger"` / `"cluster"` /
 *     `"cluster_small"`). Preferred when set: role-stable across
 *     trims.
 *   * `displayId` — explicit numeric display. Fallback when no role
 *     is given.
 *
 * Profile-gated: returns `null` when the trim has no DiShare path of
 * the requested kind —
 *   * neither `passenger == DishareQuickShare` nor
 *     `DishareQuickShare in cluster` (no DiShare at all → e.g. every
 *     Di5.1 / Generic trim; defense-in-depth even though the planner
 *     also forks on this);
 *   * a passenger/FSE tag requested but `passenger` isn't DiShare;
 *   * a cluster tag requested but the trim has no DiShare cluster.
 *
 * Wire contract pinned in [DeviceTagResolverTest]; any change to a
 * returned tag is a contract break and must update the test in
 * lockstep.
 */
object DeviceTagResolver {

    fun tagFor(
        targetRole: String?,
        displayId: Int?,
        profile: CarProfile,
    ): String? {
        val passengerOk =
            profile.capabilities.passenger == PassengerTransport.DishareQuickShare
        val clusterOk =
            ClusterCapability.DishareQuickShare in profile.capabilities.cluster
        // No DiShare path on this trim at all.
        if (!passengerOk && !clusterOk) return null

        // Role-first: stable across trims; a caller shouldn't need to
        // know which numeric id hosts the panel on the current trim.
        // Each tag is bounded by what the trim can actually paint.
        when (targetRole) {
            "passenger" ->
                return if (passengerOk) DishareTransport.DEVICE_FSE else null
            // "cluster" defaults to the top-right (driver dashboard) —
            // the larger, more user-visible surface. Callers wanting
            // the smaller centre panel pass "cluster_small".
            "cluster" ->
                return if (clusterOk) DishareTransport.DEVICE_CLUSTER_TOPRIGHT else null
            "cluster_small" ->
                return if (clusterOk) DishareTransport.DEVICE_CLUSTER_CENTER else null
        }

        // No role hint — the empirical Di5.0/BYD-container layout,
        // identical on every Di5.0 car (L5, Song PLUS, …): 2 = FSE,
        // 3 = centre panel, 4 = driver dashboard. Display 0 is the
        // IVI — never DiShare-cast (the planner returns IviLocal).
        return when (displayId) {
            DishareTransport.DISPLAY_ID_FSE ->
                if (passengerOk) DishareTransport.DEVICE_FSE else null
            DishareTransport.DISPLAY_ID_CLUSTER_CENTER ->
                if (clusterOk) DishareTransport.DEVICE_CLUSTER_CENTER else null
            DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT ->
                if (clusterOk) DishareTransport.DEVICE_CLUSTER_TOPRIGHT else null
            else -> null
        }
    }
}
