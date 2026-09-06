package com.i99dev.ilink.display

import android.view.Display
import com.i99dev.ilink.car.profiles.CarProfileRegistry

/**
 * Single source of truth for classifying an Android [Display] into a
 * mini-app-facing role. Used by both [DisplayPlatformPlugin] (so
 * `display.list` exposes the role) and the pkg family
 * (`PackagePlatformPlugin`) so launch/move can reject targets that
 * the caller's permission scope doesn't cover.
 *
 * Roles:
 *   * `ivi`        — head-unit display (id == 0). Default startActivity
 *                    target; covered by `pkg.launch`.
 *   * `passenger`  — any other addressable display whose name does
 *                    NOT match a cluster signal (Leopard 8: the
 *                    "fse" 1920×720 panel that runs as user 999).
 *                    Covered by `pkg.launch`.
 *   * `cluster`    — display in the driver's eyeline. Detected by
 *                    one of two layers, in priority order:
 *                      1. The encrypted-table marker
 *                         (`fission_bg_XDJAScreenProjection*` on L8).
 *                      2. A generic cross-OEM name heuristic — name
 *                         contains `dashboard` / `cluster` / `fission`
 *                         (case-insensitive) or `仪表` (Chinese for
 *                         "instrument cluster"). Lets us recognise
 *                         clusters on BYD trims we haven't profiled
 *                         and on non-BYD ROMs without a host update.
 *                    Covered ONLY by the `pkg.launch.cluster`
 *                    permission. We do NOT disambiguate the driver-
 *                    instrument cluster from the amap projection
 *                    slot here — the surface family owns that.
 *
 *                    NOTE: A previous Layer 3 (aspect-ratio fallback
 *                    `widthPx > heightPx*2 && heightPx ≤ 720`) was
 *                    REMOVED in 1.5.3. It misclassified BYD's standard
 *                    1920×720 FSE/passenger panels as cluster, which
 *                    broke `pkg.launch` on every BYD trim with that
 *                    panel (Song Plus etc.). The instrument-cluster
 *                    aspect ratio is NOT distinct enough from a
 *                    landscape passenger panel to use as a classifier.
 *                    If a cluster on a future ROM ships without a
 *                    name keyword, we add it to Layer 2 — never
 *                    re-introduce the aspect heuristic.
 *   * `unknown`    — reserved for displays we explicitly can't
 *                    classify in the future. The current classifier
 *                    never returns this (every non-default,
 *                    non-cluster display is treated as passenger),
 *                    but pkg.launch + pkg.move still recognise the
 *                    string and reject it so a future tightening of
 *                    the rule doesn't open a quiet hole.
 *
 * NOTE: `Display.type` (which would let us tell EXTERNAL from VIRTUAL
 * directly) is `@SystemApi` — not reachable from app code on Leopard
 * 8's API 33 SDK. The classifier therefore leans on `Display.name` +
 * cluster heuristics, which are public.
 */
object DisplayRoles {

    const val IVI = "ivi"
    const val PASSENGER = "passenger"
    const val CLUSTER = "cluster"
    const val UNKNOWN = "unknown"

    /**
     * Classify by [Display] using the active trim's [DisplayProfile]
     * — delegates to [DisplayClassifier] so the permission gate sees
     * exactly the same role the picker / SDK consumers see (single
     * source of truth: owner-package layer + name marker + name
     * keyword + cache + default). Reads the active profile from
     * [CarProfileRegistry] so callers don't need to thread it
     * through.
     */
    fun roleFor(d: Display): String =
        DisplayClassifier.classifyDisplay(
            d,
            CarProfileRegistry.forActiveCar().displays,
        ).role

    /**
     * Pure-function classifier — thin shim over
     * [DisplayClassifier.classify]. Marker is the encrypted-table
     * substring (typically `"fission"` on L8); pass an empty string
     * to skip the marker layer. `ownerPackageName` is the
     * `Display.ownerPackageName` value the Layer 1 profile override
     * consults — pass null to skip. Profile null = unprofiled boot;
     * falls through to the name heuristic exactly like
     * [DisplayClassifier].
     */
    fun classify(
        displayId: Int,
        name: String,
        widthPx: Int,
        heightPx: Int,
        marker: String,
        profile: com.i99dev.ilink.car.profiles.DisplayProfile? = null,
        ownerPackageName: String? = null,
    ): String = DisplayClassifier.classify(
        displayId = displayId,
        name = name,
        widthPx = widthPx,
        heightPx = heightPx,
        marker = marker,
        profile = profile,
        ownerPackageName = ownerPackageName,
    ).role
}
