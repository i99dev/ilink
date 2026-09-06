package com.i99dev.ilink.car.profiles

/**
 * Single source of truth for everything a single trim's behavior
 * depends on — capabilities and display picker UX.
 *
 * Replaces the previously-scattered shape (VehicleProfile +
 * VariantCapabilityProfile + isDi50Trim + isL5Family + hardcoded
 * RateLimiter constants + hardcoded family allow-lists). Adding
 * a new trim is one [CarProfile] entry in
 * `car/profiles/definitions/<trim>.kt`, registered in
 * [CarProfileRegistry.ALL]. Every gate and SDK consumer reads
 * the active profile from the registry and projects the relevant
 * sub-profile.
 *
 * The 2-cut decomposition (Display / Capability) reflects
 * distinct readers — one slice = one consumer path, no overlap.
 * See the per-sub-profile KDoc for the consumer.
 *
 * Hot path: [CarProfileRegistry.forActiveCar] is O(1) and
 * memoized. The cap-bit cache in `CapabilityRegistry.bitsForVariant`
 * is preserved unchanged.
 */
data class CarProfile(
    /** Match key — same `variantId` the detector resolves to. */
    val variantId: String?,
    /** Friendly trim name — UI label only. Backend keeps using
     *  [variantId] for routing. */
    val familyName: String,
    /** DiLink generation — drives platform-family decisions. */
    val dilinkFamily: DilinkFamily,
    /** Powertrain class — the only data-shape signal that
     *  meaningfully varies across BYD trims for mini-app UX.
     *  Drives whether mini-apps render battery-only / battery+fuel
     *  / fuel-only data surfaces. Independent of capability bits;
     *  exposed to mini-apps via [getContext().powertrain]. */
    val powertrain: Powertrain,
    /** Display-picker UX. Read by `DisplayPlatformPlugin` +
     *  `DisplayClassifier`. */
    val displays: DisplayProfile,
    /** Capability bit grants + transport choices. Read by
     *  `CapabilityRegistry.staticSeed` + `DisplayLaunchPlanner`
     *  (the Di5.0/Di5.1 transport fork). */
    val capabilities: CapabilityProfile,
)

// ── Sub-profile types ────────────────────────────────────────────

/**
 * Display-picker UX per trim.
 *
 * Consumed by:
 *   * `DisplayPlatformPlugin` — emits `hidden` / `overrideLabel` /
 *     `clusterAvailable` per display in the Dart wire shape.
 *   * `DisplayClassifier` — derives `dimReason` ("shadow",
 *     "cluster-vendor-locked") and the per-display role hints.
 *
 * The cursor/input/zoom remap maps stay co-located here because
 * they're consequences of the display topology — when a trim has
 * multiple cluster-overlay displays (L8/L5L: 3+5), the remap
 * decides which one receives input.
 */
data class DisplayProfile(
    /** Whether the OS exposes a usable instrument cluster on this
     *  trim. False on trims where the cluster Display is either
     *  not exposed or vendor-locked at SurfaceFlinger. */
    val showCluster: Boolean,
    /** Whether a second-screen passenger display is exposed (BYD
     *  internally calls this "fission 2"). True on most Di5.1
     *  trims. */
    val showFission2: Boolean,
    /** Display IDs to dim/hide from default pickers.
     *  E.g. L8: `{3, 4}` — display 3 mirrors 5; display 4 is
     *  flickery. Mini-apps can still address them by id. */
    val hiddenDisplayIds: Set<Int>,
    /** Friendlier per-display label override.
     *  E.g. L8: `{0: "Main", 2: "FSE", 5: "Driver"}`. */
    val overrideLabels: Map<Int, String>,
    /** Cursor render-target remap when the *logical* surface is
     *  the keyed display. L8: `{3 → 5, 5 → 5}`. */
    val cursorRemap: Map<Int, Int>,
    /** Touch-input target remap when input *originates from* the
     *  keyed display. L8: `{5 → 3}` — taps on cluster (5) deliver
     *  to display 3's task stack. */
    val inputRemap: Map<Int, Int>,
    /** `wm density -d N` target remap. Mirrors cursor remap on
     *  trims with a duplicated cluster. */
    val zoomRemap: Map<Int, Int>,
    /** Owner-package → intended display role for the fission slots
     *  this trim exposes. Used by `DisplayClassifier` as Layer 1
     *  (post-IVI, pre-marker): when a non-default `Display`'s
     *  `ownerPackageName` matches a key here, the role is taken
     *  from this map instead of falling through to the name-keyword
     *  heuristic — the profile is authoritative for known trims.
     *
     *  Role values are wire strings matching the `DisplayRoles`
     *  constants: `"passenger"` or `"cluster"`. Other values are
     *  ignored (the classifier falls through to the next layer).
     *
     *  Examples:
     *    * L5 / Song PLUS (Di5.0, BYD container, no usable cluster):
     *      `{"com.byd.containerservice": "passenger"}` — every
     *      fission slot is a passenger surface; the cluster is
     *      firmware-gated to platform-signed callers so we never
     *      classify it as `cluster` to begin with.
     *    * L8 / L5L (Di5.1, XDJA container, usable cluster):
     *      `{"com.xdja.containerservice": "cluster"}` — the
     *      addressable XDJA display is the driver-eyeline cluster.
     *      Trim-specific shadows (e.g. L8: 3, 4) are filtered by
     *      [hiddenDisplayIds] so the picker dims them.
     *
     *  Empty for unprofiled trims — falls through to existing
     *  name-keyword classification. Always empty on Generic (we
     *  refuse to auto-classify unknown trims; users get the
     *  manual calibration tour). */
    val secondaryDisplayOwners: Map<String, String>,
    /** Per-display cluster override. When non-null, the display
     *  whose id matches this value is classified as `cluster`
     *  regardless of [secondaryDisplayOwners] — used on Di5.0 /
     *  BYD-container trims where the cluster surface (display 4
     *  "Driver Dashboard" on L5 / Song PLUS) is owned by
     *  `com.byd.containerservice` along with the passenger slots,
     *  so the owner-package layer alone can't distinguish it.
     *  Null on trims where owner-package classification is
     *  sufficient (L8 / L5L: XDJA-owned ⇒ cluster as a class). */
    val clusterDisplayId: Int? = null,
    /** Per-display PASSENGER override — the mirror of [clusterDisplayId].
     *  When non-null, the display whose id matches is classified as
     *  `passenger` regardless of [secondaryDisplayOwners] / name. Needed
     *  on trims where the co-pilot/FSE panel is an XDJA-owned
     *  `fission_bg` display sharing both the owner (`com.xdja
     *  .containerservice`) AND the "fission" name with the driver
     *  cluster, so neither the owner-package layer nor the name keyword
     *  can tell them apart (the Leopard 8 drone-kit ROM: display 2 =
     *  FSE, displays 3+4 = split cluster, no display 5). Null on every
     *  other trim — their passenger classification is unchanged. */
    val passengerDisplayId: Int? = null,
    /** Display IDs whose cluster cast goes through OUR OWN VirtualDisplay
     *  (the reference mechanism) instead of move-task / a direct
     *  `am start --display` onto the display. Set for trims where the
     *  cluster is an XDJA OWN_CONTENT_ONLY fission display that hangs the
     *  head unit when a foreign task is moved onto it directly (Leopard 7,
     *  display 4 — verified on-car 2026-06-12). For these displays:
     *    * `DisplayClassifier` does NOT apply the `cluster-vendor-locked`
     *      dim (the cluster IS reachable, just via projection), so the
     *      picker shows it; and
     *    * the wire snapshot carries `castMode = "project"`, which the
     *      DISPLAYS drop picker routes through `pkg.projectToCluster`
     *      (ClusterActivity → private VirtualDisplay → am-start the app
     *      onto THAT) rather than `launchCluster` / move-task.
     *  Empty on every other trim — their cluster cast is unchanged. */
    val projectionCastDisplayIds: Set<Int> = emptySet(),
) {
    /** True when [displayId]'s cluster cast must go through our own
     *  VirtualDisplay projection (see [projectionCastDisplayIds]). */
    fun castsViaProjection(displayId: Int): Boolean =
        projectionCastDisplayIds.contains(displayId)

    /**
     * Hint string for [displayId] on this trim, or null if no hint
     * applies. The picker UX should DIM the display with this
     * reason but NEVER hide it. Reasons we surface today:
     *   * `"shadow"` — duplicate / mirror of another display the
     *     trim profile knows about (L8/L5L: display 3 mirrors 5).
     *   * `null` — no hint; treat as a normal addressable display.
     */
    fun dimReason(displayId: Int): String? =
        if (hiddenDisplayIds.contains(displayId)) "shadow" else null

    /** Friendlier label for [displayId] on this trim, or null to
     *  use the raw `Display.name`. */
    fun overrideLabel(displayId: Int): String? = overrideLabels[displayId]

    /** Where the cursor / pointer should render when the *logical*
     *  surface is [displayId]. Defaults to identity. */
    fun cursorDisplayFor(displayId: Int): Int = cursorRemap[displayId] ?: displayId

    /** Where touch input *originating from* [displayId] should be
     *  routed for app-level event delivery. Defaults to identity. */
    fun inputDisplayFor(displayId: Int): Int = inputRemap[displayId] ?: displayId

    /** Where `wm density -d N` should land when the user requests
     *  zoom on logical display [displayId]. Defaults to identity. */
    fun zoomDisplayFor(displayId: Int): Int = zoomRemap[displayId] ?: displayId

    /** Auto-classified role for a display owned by [ownerPackageName]
     *  on this trim, or `null` when no override applies. Returns the
     *  wire string from [secondaryDisplayOwners] (`"passenger"` /
     *  `"cluster"`); the classifier validates the value against
     *  `DisplayRoles` and ignores anything else. Null `ownerPackage
     *  Name` (the IVI / unowned displays) always returns null. */
    fun autoRoleFor(ownerPackageName: String?): String? {
        if (ownerPackageName.isNullOrEmpty()) return null
        return secondaryDisplayOwners[ownerPackageName]
    }
}

/**
 * Capability bit grants + transport choices per trim.
 *
 * Consumed by:
 *   * `CapabilityRegistry.staticSeed` — emits the cap bitmask
 *     read by every gate.
 *   * `DisplayLaunchPlanner` — the entire Di5.0(DiShare)↔
 *     Di5.1(am-start) launch fork is `passenger ==
 *     DishareQuickShare`, read here so the cap bit and the
 *     transport choice can never disagree.
 *
 * Adding a new BYD-side capability: add a new field here, set it
 * per-trim in the definitions, plumb it through
 * [toCapabilityNames]. The field type carries the empirical
 * evidence in its enum variants (e.g.
 * [BodyControlCapability.None] for trims where probes confirm
 * absence).
 */
data class CapabilityProfile(
    /** Always-on caps for every variant. Promote to a field if a
     *  trim ever needs to lack one. Per architecture decision
     *  (2026-05-06), car-control caps (`door.set`, `window.set`,
     *  `ac.get`, `ac.set`) live here uniformly across BYD —
     *  per-trim absences are handled as runtime no-ops by the
     *  daemon, not modeled in the profile. */
    val universalCaps: List<String>,
    /** How (and whether) passenger-display launches reach the
     *  user's eyeballs on this trim. */
    val passenger: PassengerTransport,
    /** Which cluster paths the trim exposes. Empty = no cluster
     *  surface usable by mini-apps. Multiple entries valid (L5L
     *  has Pixel + Icons). */
    val cluster: Set<ClusterCapability>,
) {
    /**
     * Project to the flat capability-name list consumed by
     * `VehicleCapability.bitsOf`. The order matches the
     * pre-refactor `staticSeed` body so the resulting bitmask is
     * byte-identical to the legacy procedural calculation.
     */
    fun toCapabilityNames(): List<String> {
        val caps = ArrayList<String>(universalCaps.size + 6)
        caps += universalCaps
        when (passenger) {
            PassengerTransport.None -> {}
            PassengerTransport.Fission -> {
                caps += "pkg.launch.passenger"
                caps += "surface.write.passenger"
            }
            PassengerTransport.DishareQuickShare -> {
                caps += "pkg.launch.passenger"
                caps += "pkg.launch.dishare"
            }
        }
        // Pixel and DishareQuickShare both grant the same caller-
        // visible caps — mini-apps don't care which transport
        // delivers their pixels, only that pixels are delivered.
        // The dispatcher picks the transport internally.
        if (ClusterCapability.Pixel in cluster ||
            ClusterCapability.DishareQuickShare in cluster
        ) {
            caps += "pkg.launch.cluster.pixel"
            caps += "surface.write.cluster"
        }
        if (ClusterCapability.Icons in cluster) {
            caps += "pkg.launch.cluster.icons"
        }
        return caps
    }
}

// ── Enum types ───────────────────────────────────────────────────

/** DiLink generation. */
enum class DilinkFamily {
    Di50,
    Di51,
    Unknown,
}

/**
 * How the trim delivers an app to the passenger panel.
 *
 * Each option is a typed strategy: the cap seed reads it to
 * grant the right cap bits, and the dispatcher reads it to pick
 * the transport at launch. Both reads come from the SAME profile
 * so the cap bit and dispatcher choice can never disagree.
 */
enum class PassengerTransport {
    /** Trim has no working passenger-cast path. Mini-apps
     *  targeting passenger get no cap bit. */
    None,

    /** Standard Android API: `launchDisplayId=passengerDisplayId`
     *  via ActivityOptions. Adds caps `pkg.launch.passenger` +
     *  `surface.write.passenger`. Used on Di5.1 trims and Song
     *  PLUS (Di5.0) where the XDJA fission display delivers
     *  framework pixels. */
    Fission,

    /** DiShare direct-commit transport via
     *  [com.i99dev.ilink.pkg.DishareTransport.fastCast]:
     *  bind → register → setVideoSize → setGestureShare →
     *  quickShare. Five binder transactions, no synthetic
     *  input, ~5× faster end-to-end than the legacy
     *  swipe-injection path. Adds caps `pkg.launch.passenger`
     *  + `pkg.launch.dishare`. Used on L5 + Song PLUS (Di5.0 /
     *  BYD container) where `setLaunchDisplayId` is silently
     *  dropped on the OWN_CONTENT_ONLY virtual displays. (NOT
     *  L5U — that is Di5.1/XDJA and uses `Fission`.)
     *
     *  Wire shape decompile-verified against a reference DiShare
     *  launcher — see byd/l5 RE doc + `DishareTransport.fastCast`
     *  for the binder transactions involved. */
    DishareQuickShare,
}

/**
 * Discrete cluster capabilities a trim can expose. Set-typed
 * because the Pixel and Icons paths are independent surfaces
 * with independent gating — L5L has both.
 */
enum class ClusterCapability {
    /** Direct pixel-overlay rendering surface — adds caps
     *  `pkg.launch.cluster.pixel` + `surface.write.cluster`.
     *  Mini-apps can draw their own UI. L8 + L5L. */
    Pixel,

    /** Cluster reachable via DiShare's `quickShare` op
     *  ([DishareTransport.fastCast] with `DEVICE_CLUSTER_CENTER`
     *  / `DEVICE_CLUSTER_TOPRIGHT`). Same wire as the passenger
     *  panel cast but with a different device tag. Adds caps
     *  `pkg.launch.cluster.pixel` + `surface.write.cluster` —
     *  the mini-app SDK doesn't need to distinguish between
     *  Pixel (framework-native) and DishareQuickShare
     *  (DiShare-routed) because both deliver real pixels; the
     *  selector is internal to the dispatcher. Used on L5 (Di5.0 /
     *  BYD container) where the cluster is firmware-gated against
     *  `setLaunchDisplayId`. (Song PLUS has no cluster; L5U is
     *  Di5.1/XDJA → Pixel, not this.) */
    DishareQuickShare,

    /** BYD's icon-tray API — adds cap
     *  `pkg.launch.cluster.icons`. Status-only, no Surface.
     *  L5 family (l5/l5u/l5l). */
    Icons,
}

/**
 * Vehicle powertrain class — the data-shape signal that drives
 * mini-app UX decisions about which fields to render.
 *
 * Replaces the over-modeled per-trim `bodyControl` /
 * `acControl` / `mileageRead` enums (architecture decision
 * 2026-05-06: car-control caps are uniform across BYD; the
 * real per-trim data variance is powertrain class).
 *
 * Mini-apps consume this via `getContext().powertrain` to
 * decide whether to show:
 *   * battery + EV range only (Ev)
 *   * battery + EV range + fuel + hybrid range (Phev)
 *   * small battery + range-extender + fuel (Erev)
 *   * fuel only (Ice)
 *
 * Discriminator at probe time: `byd_content_providers
 * .dicare_record.columns`. Presence of `hev_mileage` ⇒ Phev
 * or Erev; presence of `total_mileage` only with EV-related
 * vendor_props ⇒ Ev; fuel-only vendor_props ⇒ Ice.
 */
enum class Powertrain {
    /** Pure battery EV — battery + EV range. No fuel UI. */
    Ev,

    /** Plug-in hybrid — battery + EV range + fuel + hybrid
     *  trip log. Most current BYD trims (Leopard 5/7/8/HanL,
     *  Song PLUS DM-i) are PHEV. */
    Phev,

    /** Range-extender EV — small battery driven by an on-board
     *  fuel-burning generator. Treats the engine as a
     *  charger, not a driver. Less common but distinguishable
     *  from PHEV by drive-mode telemetry. */
    Erev,

    /** Pure ICE — fuel only. Rare in BYD's current lineup. */
    Ice,

    /** Probe didn't establish powertrain. Mini-apps should
     *  render the conservative default (battery + fuel both
     *  shown if data present). */
    Unknown,
}
