package com.i99dev.ilink.display

import com.i99dev.ilink.car.profiles.DilinkFamily
import com.i99dev.ilink.car.profiles.PassengerTransport

/**
 * THE single, pure policy for "how do we safely place an app on a secondary
 * display, given the DiLink generation and what we can observe about the
 * display right now?".
 *
 * This centralises a decision that was previously split across three places:
 *   * [DisplayLaunchPlanner] (am-start vs DiShare vs shell, by `passenger`),
 *   * the per-trim `DisplayProfile.projectionCastDisplayIds` (the L7 "use a
 *     VirtualDisplay" flag), surfaced to Dart as `castMode`,
 *   * the Dart picker, which read `castMode` to pick `projectToCluster` vs
 *     `launchCluster`.
 *
 * The cluster-cast SAFETY decision (launch-onto vs project-via-our-own-VD) is
 * the dangerous one: moving a foreign task onto a Di5.1 **group-0 fission**
 * display drags the host's own activity onto the cluster and hangs the car
 * (the L7 bug). Today that's avoided only by a hand-authored per-trim flag —
 * so an *unknown* Di5.1/XDJA car defaults to the hanging path. This policy
 * makes the safety decision **derive from runtime display facts** (display
 * group vs the IVI's group, owner/name signals) keyed on the DiLink family,
 * with an explicit **fail-safe: an unidentified Di5.1 cluster is projected,
 * never move-tasked**. New cars in a known family then work safely with no
 * profile edit.
 *
 * Purity: no Android imports — every input is a plain value the caller reads
 * once from the [android.view.Display] + active profile. O(1), nothing
 * allocated. Scalability: a new generation or cast-class is one `when` arm;
 * a new trim is zero code (facts + family decide). Maintenance: this object +
 * the two closed enums are the whole surface.
 *
 * PHASE 1 (current): computed read-only and surfaced in the display snapshot
 * for on-car verification — it does NOT yet drive the launch path. Later
 * phases route [DisplayLaunchPlanner] through [mechanismFor].
 */
object ClusterCastPolicy {

    /**
     * What kind of cluster surface this display is, from the safety angle.
     * Only meaningful when the display's role is `cluster`.
     */
    enum class ClusterCastClass {
        /** Not a cluster (IVI / passenger / unknown role). */
        NotCluster,

        /** Di5.1 XDJA cluster on its OWN display group — `am start --display`
         *  lands cleanly (L8, L5L, L5U / display 5). */
        LaunchableXdja,

        /** Di5.1 cluster that shares the IVI's display group (group-0 fission)
         *  or is a `*ScreenProjection*` background layer — move-task here drags
         *  the host activity onto it and HANGS. Must cast via our own
         *  VirtualDisplay (the reference/L7 path). */
        Group0FissionHazard,

        /** Di5.0 BYD-container cluster — DiShare `quickShare` acks but never
         *  paints the cluster on these ROMs; reached only by the privileged
         *  shell `am start` (L5, Song PLUS, Sealion 6). */
        BydContainerCluster,

        /** Di5.1 cluster we can't positively place on its own group (no group
         *  signal, no profile). Treated as a hazard → projected (fail-safe). */
        UnknownCluster,
    }

    /** The transport that actually places the app on the target display. */
    enum class CastMechanism {
        /** Plain `Context.startActivity` on the IVI. */
        IviLocal,

        /** Framework `am start --display N` (Di5.1 passenger + launchable
         *  XDJA cluster). */
        AmStart,

        /** Cast via OUR OWN VirtualDisplay + Presentation (the L7-safe
         *  the reference path) — never enters the foreign group-0. */
        Project,

        /** Privileged shell `am start -S --display N` (Di5.0 cluster). */
        ShellLaunch,

        /** DiShare `quickShare` binder commit (Di5.0 passenger / FSE). */
        Dishare,

        /** Genuinely not reachable on this car. */
        Unreachable,
    }

    /**
     * Classify a CLUSTER display's cast-class from observable facts. Callers
     * pass the role already resolved by [DisplayClassifier]; non-cluster roles
     * short-circuit to [ClusterCastClass.NotCluster].
     *
     * @param role               resolved role string (`DisplayRoles.*`).
     * @param family             the trim's DiLink generation.
     * @param displayGroupId     this display's group id, or null if unknown
     *                           (reflection unavailable / pre-group ROM).
     * @param iviGroupId         the IVI (display 0) group id, or null.
     * @param name               the display name (for projection-bg signals).
     * @param profileSaysProject the per-trim `castsViaProjection` hint —
     *                           honoured as a positive override during the
     *                           transitional phase (L7).
     */
    fun classifyCastClass(
        role: String,
        family: DilinkFamily,
        displayGroupId: Int?,
        iviGroupId: Int?,
        name: String,
        profileSaysProject: Boolean,
    ): ClusterCastClass {
        if (role != DisplayRoles.CLUSTER) return ClusterCastClass.NotCluster

        if (family == DilinkFamily.Di50) return ClusterCastClass.BydContainerCluster

        // Di5.1 (XDJA) — or unknown generation, treated like Di5.1 since the
        // dangerous move-task path is the framework one.
        val sharesIviGroup =
            displayGroupId != null && iviGroupId != null && displayGroupId == iviGroupId
        val projectionBgName =
            name.contains("ScreenProjection", ignoreCase = true) ||
                name.contains("fission_bg", ignoreCase = true)
        if (profileSaysProject || sharesIviGroup || projectionBgName) {
            return ClusterCastClass.Group0FissionHazard
        }
        // A cluster on its own (non-IVI) display group is a clean launchable
        // XDJA surface (L8/L5U/L5L display 5).
        if (displayGroupId != null && iviGroupId != null && displayGroupId != iviGroupId) {
            return ClusterCastClass.LaunchableXdja
        }
        // No usable group signal → don't risk the hang: project.
        return ClusterCastClass.UnknownCluster
    }

    /**
     * The mechanism for a target, given the family, the trim's passenger
     * transport, the resolved role, and (for clusters) the cast-class.
     *
     * Matches today's [DisplayLaunchPlanner] behaviour on KNOWN cars (so the
     * read-only derived value can be compared 1:1 on-car), and adds the
     * safe-by-default behaviour for the cases the static profile didn't cover:
     * an [ClusterCastClass.UnknownCluster] (or any [Group0FissionHazard]) is
     * [CastMechanism.Project], never a move-task.
     */
    fun mechanismFor(
        role: String,
        family: DilinkFamily,
        passenger: PassengerTransport,
        castClass: ClusterCastClass,
    ): CastMechanism {
        return when (role) {
            DisplayRoles.IVI -> CastMechanism.IviLocal
            DisplayRoles.PASSENGER -> when (passenger) {
                PassengerTransport.DishareQuickShare -> CastMechanism.Dishare
                PassengerTransport.Fission -> CastMechanism.AmStart
                PassengerTransport.None -> CastMechanism.Unreachable
            }
            DisplayRoles.CLUSTER -> when (castClass) {
                ClusterCastClass.LaunchableXdja -> CastMechanism.AmStart
                ClusterCastClass.Group0FissionHazard -> CastMechanism.Project
                ClusterCastClass.UnknownCluster -> CastMechanism.Project
                ClusterCastClass.BydContainerCluster -> CastMechanism.ShellLaunch
                ClusterCastClass.NotCluster -> CastMechanism.Unreachable
            }
            else -> CastMechanism.Unreachable
        }
    }

    /** Lowercase wire token for the snapshot / diagnostics. */
    fun wireToken(m: CastMechanism): String = when (m) {
        CastMechanism.IviLocal -> "ivi_local"
        CastMechanism.AmStart -> "am_start"
        CastMechanism.Project -> "project"
        CastMechanism.ShellLaunch -> "shell_launch"
        CastMechanism.Dishare -> "dishare"
        CastMechanism.Unreachable -> "unreachable"
    }

    /** Lowercase wire token for the cast-class. */
    fun wireToken(c: ClusterCastClass): String = when (c) {
        ClusterCastClass.NotCluster -> "not_cluster"
        ClusterCastClass.LaunchableXdja -> "launchable_xdja"
        ClusterCastClass.Group0FissionHazard -> "group0_fission_hazard"
        ClusterCastClass.BydContainerCluster -> "byd_container_cluster"
        ClusterCastClass.UnknownCluster -> "unknown_cluster"
    }
}
