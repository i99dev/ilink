package com.i99dev.ilink.display

import android.view.Display
import com.i99dev.ilink.car.profiles.DisplayProfile
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import java.lang.reflect.Method

/**
 * Single source of truth for display classification — replaces the
 * fragmented logic that previously lived across `DisplayRoles.kt`,
 * `VehicleProfile.kt` (role-relevant bits), and `display_snapshot.dart`.
 *
 * Returns a [Classification] with:
 *   * `role` — `ivi` / `passenger` / `cluster` / `unknown`. The same
 *     string set the host's permission gates check
 *     (`PackagePlatformPlugin` reads it for `pkg.launch.cluster`).
 *   * `source` — which classifier layer fired. Lets observability +
 *     mini-apps know how confident the result is.
 *   * `confidence` — coarse HIGH/MEDIUM tier. HIGH means a positive
 *     signal fired (encrypted marker / name keyword / cache hit).
 *     MEDIUM means we fell through to the safe default (passenger).
 *   * `dimReason` — hint string when the active VehicleProfile thinks
 *     this display is a duplicate / shadow on this trim, OR when the
 *     trim's cluster is vendor-locked (third-party-unreachable). The
 *     picker UX should dim the display with this reason but NEVER
 *     hide it outright — a hidden display the user can't reach is
 *     harder to diagnose than a visible "may not be reachable" one.
 *
 *     Reasons emitted today:
 *     - `"shadow"` — duplicate / mirror of another display the trim
 *       profile knows about (e.g. L8/L5L: display 3 mirrors 5).
 *     - `"cluster-vendor-locked"` — the cluster is a real display but
 *       BYD's firmware only forwards platform-signed callers' frames
 *       to the physical panel (e.g. L5 base —
 *       .secrets/research/l5/REPORT.md). Picker should dim the card
 *       and tooltip "BYD-signed only on this trim."
 *
 * Layers, in priority order:
 *   1. Owner-package profile override (`OWNER_PKG`, HIGH confidence).
 *      When the active trim's profile has a `secondaryDisplayOwners`
 *      entry matching this display's `Display.ownerPackageName`, the
 *      profile's role wins over every heuristic below. This is what
 *      lets DiLink 5.0 (BYD-container) fission slots classify as
 *      *passenger* even though their names contain "fission" — the
 *      name marker would otherwise misclassify them as cluster on
 *      a trim where the cluster is firmware-locked.
 *   2. Encrypted-table marker (`fission_bg_XDJAScreenProjection*` on
 *      L8) → `MARKER`, HIGH confidence.
 *   3. Cross-OEM name keyword (`dashboard` / `cluster` / `fission` /
 *      `仪表`) → `NAME_KW`, HIGH confidence.
 *   4. Cache hit from [DisplayMemory] (a previous successful
 *      `pkg.launch` recorded this `(name, w, h)` tuple → role).
 *      Promoted to HIGH because the launch actually succeeded —
 *      empirical truth beats the table. **Only consulted when the
 *      first three layers miss.**
 *   5. Default → `DEFAULT`, MEDIUM confidence, role=`PASSENGER`.
 *      Permissive on purpose: the cost of a true cluster being
 *      addressable as passenger is "minor UX confusion"; the cost
 *      of a true passenger panel mis-tagged as cluster is "pkg.launch
 *      breaks silently" — much harder to diagnose. We pick the
 *      recoverable error direction.
 *
 * Removed in 1.5.3: the aspect-ratio fallback (`w > h*2 && h ≤ 720`)
 * misclassified BYD's standard 1920×720 FSE/passenger panel as
 * cluster, breaking `pkg.launch` on Song Plus + every BYD trim with
 * that panel. The instrument-cluster aspect ratio is not distinct
 * enough from a landscape passenger panel to use as a classifier;
 * if a future ROM ships a cluster without a name keyword, add it
 * to Layer 2 — never re-introduce the aspect heuristic.
 */
object DisplayClassifier {

    enum class Source { OWNER_PKG, MARKER, NAME_KW, CACHE_HIT, DEFAULT }
    enum class Confidence { HIGH, MEDIUM }

    /** Cached reflection handle for `Display.getOwnerPackageName()` —
     *  the method is `@hide` so app code can't call it directly, but
     *  it's been stable across every Android version we ship to.
     *  Lazy so devices without the method (some custom ROMs) just see
     *  null and fall through to name-based classification rather than
     *  crashing. One-time lookup; subsequent calls reuse the handle. */
    @Volatile private var ownerPackageMethod: Method? = null
    @Volatile private var ownerPackageMethodResolved: Boolean = false

    private fun readOwnerPackageName(d: Display): String? {
        if (!ownerPackageMethodResolved) {
            synchronized(this) {
                if (!ownerPackageMethodResolved) {
                    ownerPackageMethod = runCatching {
                        Display::class.java.getMethod("getOwnerPackageName")
                    }.getOrNull()
                    ownerPackageMethodResolved = true
                }
            }
        }
        val m = ownerPackageMethod ?: return null
        return runCatching { m.invoke(d) as? String }.getOrNull()
    }

    data class Classification(
        val role: String,
        val source: Source,
        val confidence: Confidence,
        val dimReason: String?,
    )

    /**
     * Convenience: classify by [Display]. Reads name + dimensions from
     * the Display itself; for tests / call sites that already have
     * metrics in hand, prefer [classify].
     *
     * `profile` is the active trim's [DisplayProfile] — drives both
     * the per-display `dimReason` hint and the owner-package role
     * override (Layer 1). Pass `null` to skip both (tests /
     * unprofiled boots fall through to name-based classification).
     *
     * The `secondaryDisplayOwners` map on [DisplayProfile] is the
     * single source of truth for owner-package → role overrides:
     *   * Di5.0 trims (L5, Song Plus) map `com.byd.containerservice`
     *     to `passenger` — fission slots are passenger surfaces; the
     *     cluster is firmware-locked.
     *   * Di5.1 trims (L8, L5L) map `com.xdja.containerservice` to
     *     `cluster` — XDJA-owned displays are the driver eyeline.
     * Generic / unprofiled trims keep the map empty so we never
     * auto-classify without a matched profile.
     */
    fun classifyDisplay(d: Display, profile: DisplayProfile?): Classification {
        val name = d.name ?: ""
        val size = android.graphics.Point()
        @Suppress("DEPRECATION")
        d.getRealSize(size)
        return classify(
            displayId = d.displayId,
            name = name,
            widthPx = size.x,
            heightPx = size.y,
            marker = MiniAppShellCommands.clusterNameMarker(),
            profile = profile,
            ownerPackageName = readOwnerPackageName(d),
        )
    }

    /**
     * Pure-function classifier — no Android dependency. `marker` is
     * the encrypted-table substring (typically `"fission"` on L8);
     * pass an empty string to skip the marker layer.
     * `ownerPackageName` is the `Display.ownerPackageName` value;
     * pass null to skip Layer 1 (owner-package profile override).
     */
    fun classify(
        displayId: Int,
        name: String,
        widthPx: Int,
        heightPx: Int,
        marker: String,
        profile: DisplayProfile?,
        ownerPackageName: String? = null,
    ): Classification {
        val raw = classifyRaw(
            displayId = displayId,
            name = name,
            widthPx = widthPx,
            heightPx = heightPx,
            marker = marker,
            profile = profile,
            ownerPackageName = ownerPackageName,
        )
        val baseDimReason = profile?.dimReason(displayId)
        // Vendor-locked cluster: the trim's profile says the cluster
        // can't be reached by third-party apps (e.g. L5 base — see
        // .secrets/research/l5/REPORT.md). The display is still real;
        // the picker should DIM the card with this reason and surface
        // a tooltip, not hide it.
        val finalDimReason = when {
            // Projection-cast cluster (L7 display 4): the cluster IS
            // reachable via our own VirtualDisplay (the reference path), so
            // it must NOT be dimmed vendor-locked — the picker shows it
            // and routes a drop through pkg.projectToCluster.
            profile != null && profile.castsViaProjection(displayId) -> baseDimReason
            raw.role == DisplayRoles.CLUSTER &&
                profile != null && !profile.showCluster -> "cluster-vendor-locked"
            else -> baseDimReason
        }
        return raw.copy(dimReason = finalDimReason)
    }

    private fun classifyRaw(
        displayId: Int,
        name: String,
        widthPx: Int,
        heightPx: Int,
        marker: String,
        profile: DisplayProfile?,
        ownerPackageName: String?,
    ): Classification {
        if (displayId == Display.DEFAULT_DISPLAY) {
            return Classification(
                role = DisplayRoles.IVI,
                source = Source.DEFAULT,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        // Layer 0: per-display cluster pin. On Di5.0/BYD-container
        // trims the cluster and passenger slots share one owner
        // (`com.byd.containerservice`) so the owner-package layer
        // alone can't tell them apart — the profile pins the
        // cluster id explicitly (`clusterDisplayId = 4` on L5 /
        // Song PLUS). When set, that id is the cluster regardless
        // of owner; remaining ids fall through to Layer 1 below.
        if (profile?.clusterDisplayId == displayId) {
            return Classification(
                role = DisplayRoles.CLUSTER,
                source = Source.OWNER_PKG,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        // Layer 0.5: per-display passenger pin — the mirror of the
        // cluster pin above. On the Leopard 8 drone-kit ROM the FSE /
        // co-pilot panel is an XDJA-owned `fission_bg` display (display
        // 2) that shares its owner AND its "fission" name with the
        // driver cluster (3/4), so the owner-package (Layer 1) and
        // name-keyword (Layer 3) layers would both misclassify it as
        // cluster. The profile pins the passenger id explicitly; remaining
        // ids fall through to the owner layer (→ cluster) below.
        if (profile?.passengerDisplayId == displayId) {
            return Classification(
                role = DisplayRoles.PASSENGER,
                source = Source.OWNER_PKG,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        // Layer 1: owner-package profile override. The active trim's
        // profile is authoritative — when its secondaryDisplayOwners
        // map names this display's owner, that role wins over every
        // heuristic below. Validates the role string against the
        // known DisplayRoles set so a typo'd profile entry falls
        // through to the next layer rather than emitting an invalid
        // role into the wire shape.
        if (profile != null && !ownerPackageName.isNullOrEmpty()) {
            val ownerRole = profile.autoRoleFor(ownerPackageName)
            if (ownerRole == DisplayRoles.PASSENGER || ownerRole == DisplayRoles.CLUSTER) {
                return Classification(
                    role = ownerRole,
                    source = Source.OWNER_PKG,
                    confidence = Confidence.HIGH,
                    dimReason = null,
                )
            }
        }
        if (marker.isNotEmpty() && name.contains(marker, ignoreCase = true)) {
            return Classification(
                role = DisplayRoles.CLUSTER,
                source = Source.MARKER,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        if (
            name.contains("dashboard", ignoreCase = true) ||
            name.contains("cluster", ignoreCase = true) ||
            name.contains("fission", ignoreCase = true) ||
            name.contains("仪表")
        ) {
            return Classification(
                role = DisplayRoles.CLUSTER,
                source = Source.NAME_KW,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        val cached = DisplayMemory.lookup(name, widthPx, heightPx)
        if (cached != null) {
            return Classification(
                role = cached,
                source = Source.CACHE_HIT,
                confidence = Confidence.HIGH,
                dimReason = null,
            )
        }
        return Classification(
            role = DisplayRoles.PASSENGER,
            source = Source.DEFAULT,
            confidence = Confidence.MEDIUM,
            dimReason = null,
        )
    }
}
