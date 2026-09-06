package com.i99dev.ilink.display

import com.i99dev.ilink.car.profiles.CarProfile
import com.i99dev.ilink.car.profiles.PassengerTransport
import com.i99dev.ilink.pkg.DeviceTagResolver
import com.i99dev.ilink.pkg.DishareTransport

/**
 * THE single decision point for "how does a launch reach a display
 * on this car?". Every launch surface — native drag-drop, the
 * slide-panel sheet, mini-app `pkg.launch`, mini-app
 * `surface.create` — funnels through [plan]; the call sites become
 * thin (resolve a target + execute the returned [LaunchPlan]).
 *
 * Inputs are the minimum that actually determine the answer, all
 * already available — there are deliberately **no per-display /
 * per-model tables** (that approach didn't scale and regressed):
 *   * the display **role** — from the central [DisplayClassifier]
 *     (passed in as [roleResolver] so this stays pure + unit-test
 *     -able);
 *   * the trim's **transport class** — `capabilities.passenger`
 *     (`DishareQuickShare` ⇒ Di5.0/BYD, else am-start/Di5.1). This
 *     one boolean is the entire generation fork;
 *   * the **content kind** — a foreign installed app vs the
 *     mini-app's own content.
 *
 * Performance: O(1) — a memoized profile + one role lookup + a
 * couple of enum compares; nothing allocated per display.
 * Scalability: a new known trim sets one capability field; an
 * unknown trim is handled by the Generic profile (cluster stays
 * conservative). Maintenance: this object + the closed [LaunchPlan]
 * + the executors is the whole surface.
 *
 * The Di5.0 device-tag lookup is delegated to [DeviceTagResolver]
 * (a small container-uniform map); the am-start / DiShare /
 * Presentation **executors are unchanged** — this only decides.
 */
object DisplayLaunchPlanner {

    /** What the caller wants to reach. */
    sealed interface Target {
        /** A concrete display the caller already resolved from
         *  `display.list` (the normal case: picker, sheet,
         *  pkg-launcher, surface). */
        data class Display(val id: Int) : Target

        /** Semantic only — no displayId (legacy `pkg.launch`
         *  `targetRole`). [small] selects the centre cluster panel
         *  over the driver-dashboard one. */
        data class Role(val role: String, val small: Boolean = false) : Target
    }

    enum class ContentKind {
        /** A foreign installed Android app (`pkg.launch`). */
        ForeignApp,

        /** The mini-app's own content (`surface.create`). */
        OwnContent,
    }

    /** Closed set of outcomes. The executor switches on this. */
    sealed interface LaunchPlan {
        /** Plain `Context.startActivity` on the IVI. */
        object IviLocal : LaunchPlan

        /** DiShare `quickShare` with this device tag. */
        data class Dishare(val deviceTag: String) : LaunchPlan

        /** Framework `am start --display` onto this id (Di5.1). */
        data class AmStart(val displayId: Int) : LaunchPlan

        /** Di5.0 cluster: START the app directly on the cluster
         *  display via the privileged shell bridge — a faithful port
         *  of the user's working Shaheen `RouteEngine.launchCluster`
         *  (`am start -S --display N --activity-multiple-task
         *  --activity-clear-top -n <component>` over the embedded ADB
         *  self-bridge, which runs as shell uid so the start is NOT
         *  dropped on the otherwise-restricted cluster display).
         *  DiShare `quickShare` does NOT mirror the cluster on this
         *  ROM — this is the only path that lands an app there. */
        data class ShellLaunch(val displayId: Int) : LaunchPlan

        /** Host-rendered surface (Presentation / overlay /
         *  am-start-host-activity) on this id — own content. */
        data class SurfaceCreate(val displayId: Int) : LaunchPlan

        /** Genuinely not reachable on this car. Surface honestly
         *  (the #127 launch-outcome decoder renders it as a clean
         *  failure) — never silently drop. */
        data class Unreachable(val reason: String) : LaunchPlan
    }

    /**
     * @param roleResolver displayId → role string, i.e. the central
     *   [DisplayClassifier] (`DisplayRoles.roleFor`). Injected so
     *   this function is pure.
     * @param expectCluster the caller used the `pkg.launch_cluster`
     *   permission tier — enforce the target really is the cluster
     *   (defense-in-depth on the am-start trims; on DiShare trims the
     *   BYD slots classify `passenger` and cluster reachability is
     *   the device tag's job, so the gate is skipped there, matching
     *   the long-standing Di5.0 behaviour).
     */
    fun plan(
        target: Target,
        contentKind: ContentKind,
        profile: CarProfile,
        roleResolver: (Int) -> String,
        expectCluster: Boolean = false,
    ): LaunchPlan {
        // Own content (surface.create) — always the host-rendered
        // surface, every display, both generations.
        if (contentKind == ContentKind.OwnContent) {
            return when (target) {
                is Target.Display -> LaunchPlan.SurfaceCreate(target.id)
                is Target.Role ->
                    LaunchPlan.Unreachable("own content needs a resolved display id")
            }
        }

        // Foreign app. Role is only consulted for the IVI short-
        // circuit and the Di5.1 permission gate — NOT for Di5.0 tag
        // selection (see below).
        val role = when (target) {
            is Target.Display -> roleResolver(target.id)
            is Target.Role -> target.role
        }
        if (role == DisplayRoles.IVI) return LaunchPlan.IviLocal

        val dishare =
            profile.capabilities.passenger == PassengerTransport.DishareQuickShare

        if (dishare) {
            // Di5.0 / BYD. The classifier reports EVERY BYD slot as
            // `passenger`, so the displayId — not the role — is the
            // surface discriminator (the uniform `2=fse · 3=cluster_c
            // · 4=cluster_tr` container layout). A `Display` target
            // therefore resolves by numeric id; resolving by the
            // uniform role would collapse the driver onto the
            // co-pilot (the original regression). A role-only target
            // has no id and resolves role-first.
            val tag = when (target) {
                is Target.Display ->
                    DeviceTagResolver.tagFor(null, target.id, profile)
                is Target.Role -> {
                    val roleArg =
                        if (target.role == DisplayRoles.CLUSTER && target.small) {
                            "cluster_small"
                        } else {
                            target.role
                        }
                    DeviceTagResolver.tagFor(roleArg, null, profile)
                }
            }
            return when (tag) {
                null ->
                    LaunchPlan.Unreachable("no DiShare path to the requested display")
                // Cluster (centre / driver-dashboard) is NOT a
                // DiShare-mirror surface on this ROM: quickShare to
                // `cluster_c`/`cluster_tr` returns ok at the binder
                // layer but never paints. The user's working Shaheen
                // app reaches the cluster via `RouteEngine
                // .launchCluster` → `am start --display N` over a
                // shell-uid bridge. Route there.
                DishareTransport.DEVICE_CLUSTER_TOPRIGHT ->
                    LaunchPlan.ShellLaunch(DishareTransport.DISPLAY_ID_CLUSTER_TOPRIGHT)
                DishareTransport.DEVICE_CLUSTER_CENTER ->
                    LaunchPlan.ShellLaunch(DishareTransport.DISPLAY_ID_CLUSTER_CENTER)
                // FSE / passenger stays the DiShare mirror path (the
                // callback-binder fix repaired it; DiShare's own
                // service acks our client by package name).
                else -> LaunchPlan.Dishare(tag)
            }
        }

        // Di5.1 / am-start. The role/permission gate lives here (it
        // was the standalone `checkDisplayRole`): on framework trims
        // the classified role is authoritative.
        if (expectCluster) {
            if (role != DisplayRoles.CLUSTER) {
                return LaunchPlan.Unreachable("expected_cluster_got_$role")
            }
        } else if (role == DisplayRoles.CLUSTER) {
            return LaunchPlan.Unreachable("requires_cluster_op")
        } else if (role != DisplayRoles.PASSENGER) {
            return LaunchPlan.Unreachable("role:unknown")
        }

        // A role-only target with no resolved id has no specific
        // display to target → the long-standing default-display
        // launch.
        return when (target) {
            is Target.Display -> LaunchPlan.AmStart(target.id)
            is Target.Role -> LaunchPlan.IviLocal
        }
    }
}
