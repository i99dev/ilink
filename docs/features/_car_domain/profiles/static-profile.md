# Static trim profile

The static profile is the single source of truth for "what does this
trim expose". One file per trim under
[`car/profiles/definitions/`](../../../../android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/definitions/),
all assembled into a registry the host plugins read on every hot
path.

```
android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/
├── CarProfile.kt           ← data class + sub-profiles + enums
├── CarProfileRegistry.kt   ← O(1) lookup, active-car cache
└── definitions/
    ├── Constants.kt        ← STANDARD_UNIVERSAL_CAPS
    ├── Leopard5.kt         ← l5
    ├── Leopard5Lidar.kt    ← l5l
    ├── Leopard5Ultra.kt    ← l5u
    ├── Leopard7.kt         ← l7
    ├── Leopard8.kt         ← l8
    ├── BydHanL.kt          ← han_l
    ├── SongPlus.kt         ← song_plus
    ├── FSeries.kt          ← 5f
    └── Generic.kt          ← null variantId fallback
```

## The shape

```kotlin
data class CarProfile(
    val variantId: String?,            // 'l8', 'l5', ..., null = Generic
    val familyName: String,            // UI label
    val dilinkFamily: DilinkFamily,    // Di50 / Di51 / Unknown
    val powertrain: Powertrain,        // Ev / Phev / Erev / Ice / Unknown

    val displays: DisplayProfile,
    val capabilities: CapabilityProfile,
)
```

The 2-cut sub-profile decomposition matches **distinct readers** —
each slice has exactly one consumer path so the cuts never overlap
and never need cross-referencing. (`familyCode40d` / `modelVariant`
/ a `triage` sub-profile were removed — no consumer ever read them;
Sentry trim tags come from the Dart detector. The 40d / variant
codes survive as documented probe provenance in each definition's
KDoc.)

## Sub-profile #1 — DisplayProfile

Read by `DisplayPlatformPlugin` and `DisplayClassifier`. Drives the
display-picker UX surfaced in pkg-launcher / dash-wallpaper and
controls cursor + input remap on trims with mirrored cluster
displays.

| Field | What it does |
|---|---|
| `showCluster` | Whether the OS exposes a usable cluster surface on this trim. False where the cluster is genuinely unreachable (L7 / HAN L fission-no-cluster; F-series). **True on Di5.0 L5 / Song PLUS** — the Driver Dashboard (display 4) is reachable; cluster pixels are DiShare-routed (`cluster_tr`) rather than framework-native, but they *are* reachable. |
| `showFission2` | Whether the second-screen passenger display ("fission 2" in BYD-speak) is exposed. |
| `hiddenDisplayIds` | Display IDs to dim in default pickers. L8 hides `{3, 4}` (3 mirrors 5; 4 is flickery). Di5.0 hides `{3}` (Small Panel — a silent-failing cast target on its own). Mini-apps can still address them by id. |
| `overrideLabels` | Per-display friendly label override (`{0:"Main", 2:"FSE", 5:"Driver"}` on L8; `{2:"FSE Co-pilot", 3:"Small Panel", 4:"Driver Dashboard"}` on Di5.0). |
| `clusterDisplayId` | `Int?` — per-display cluster pin. When non-null, the keyed display is classified `cluster` **before** the owner-package layer, regardless of `secondaryDisplayOwners`. Needed on Di5.0 (`= 4` on `DI50_BYD_DISHARE`): the Driver Dashboard and the passenger slots share one owner (`com.byd.containerservice`) so the owner-package rule alone can't tell them apart. Null on Di5.1 (XDJA-owned ⇒ cluster as a class — owner-package classification suffices). |
| `cursorRemap` | Remap when *logical* surface is the keyed display. L8: `{3→5, 5→5}` so the pointer lands on the visible eyeline cluster. **Empty (identity) on Di5.0** — displays 3/4 are siblings (no parent/child mirror), so the cursor stays on the visible Driver Dashboard (4). |
| `inputRemap` | Remap when input *originates from* the keyed display. L8: `{5→3}` — taps on cluster 5 deliver to the task stack on display 3. **Di5.0: `{4→2}`** — display 4 has no touchable window; the cast app's focusable window lives on the DiShare source display (2). |
| `zoomRemap` | `wm density -d N` target remap. Mirrors `cursorRemap` on duplicated-cluster trims. |
| `secondaryDisplayOwners` | `Map<String, String>` of owner-package → role wire string (`"passenger"` / `"cluster"`). Drives `DisplayClassifier` **Layer 1** (after the `clusterDisplayId` Layer 0 pin): when `Display.ownerPackageName` matches a key here, the profile's role wins over name-substring heuristics. Also feeds the Dart auto-seed in `DisplayCalibrationController.tryAutoSeedFromDisplays` so known trims skip the manual calibration tour. Examples: `{"com.byd.containerservice": "passenger"}` (Di5.0 — L5, Song Plus; the cluster is carved out by `clusterDisplayId`), `{"com.xdja.containerservice": "cluster"}` (Di5.1 — L8, L5L). Empty on Generic / unprofiled trims. |

Helpers on `DisplayProfile`: `dimReason(displayId)`,
`overrideLabel(displayId)`, `cursorDisplayFor(...)`,
`inputDisplayFor(...)`, `zoomDisplayFor(...)`,
`autoRoleFor(ownerPackageName)`. The `clusterDisplayId` field is read
directly by `DisplayClassifier` (Layer 0) — no helper.

## Sub-profile #2 — CapabilityProfile

Read by `CapabilityRegistry.staticSeed` (which produces the cap
bitmask consumed by every gate) and `PackagePlatformPlugin
.shouldUseDishare` (which picks the passenger transport at launch
time).

```kotlin
data class CapabilityProfile(
    val universalCaps: List<String>,      // STANDARD_UNIVERSAL_CAPS today
    val passenger: PassengerTransport,    // None / Fission / DishareQuickShare
    val cluster: Set<ClusterCapability>,  // {} or {Pixel}, {Icons}, {Pixel,Icons}, {DishareQuickShare,Icons}
)
```

`toCapabilityNames()` projects this to the flat string list the
legacy `staticSeed` body produced — byte-identical bitmask output.
The order matters because `VehicleCapability.bitsOf` hashes positionally.

### Why both `cap bit` and `dispatcher choice` come from the same field

`PassengerTransport` is the single read for both:

- **Cap seed** — `Fission` adds `pkg.launch.passenger` +
  `surface.write.passenger`; `DishareQuickShare` adds
  `pkg.launch.passenger` + `pkg.launch.dishare`; `None` grants nothing.
- **Dispatcher** — `DisplayLaunchPlanner` reads
  `passenger == DishareQuickShare` directly to decide whether to
  route to the DiShare `fastCast` / shell-launch path or call
  `setLaunchDisplayId` via ActivityOptions (the framework am-start
  path on Di5.1).

Because both reads come from one field, the cap bit and the
dispatcher choice **cannot disagree**. This was a real bug source
pre-refactor.

### `ClusterCapability` is a Set, not an enum

Pixel and Icons are independent surfaces with independent gating:

- **Pixel** — direct pixel-overlay rendering surface. Adds
  `pkg.launch.cluster.pixel` + `surface.write.cluster`. Mini-apps
  can draw their own UI. (L8, L5L)
- **Icons** — BYD's icon-tray API. Status-only, no Surface. Adds
  `pkg.launch.cluster.icons`. (L5, L5U, L5L)

L5L exposes both → `setOf(Pixel, Icons)`.

### `STANDARD_UNIVERSAL_CAPS`

Always-on caps every trim grants today (defined in `Constants.kt`):

```
display.read, pkg.read, pkg.launch.ivi, surface.write.ivi,
cursor.write, gesture.dispatch, ac.get, ac.set, door.set, window.set
```

Per architecture decision **2026-05-06**, car-control caps
(`door.set`, `window.set`, `ac.get`, `ac.set`) live in the universal
list across BYD. Per-trim absences are handled as runtime no-ops by
the daemon, not modeled in the profile. If that decision is ever
revisited, promote the cap to a per-trim field on `CapabilityProfile`
and update `toCapabilityNames()`.

## Enums

### `DilinkFamily`

`Di50` / `Di51` / `Unknown`. Drives platform-family decisions —
which display-owner package to look for, which AIDL surface to
attempt, etc.

### `PassengerTransport`

`None` / `Fission` / `DishareQuickShare`. See the explanation above
under CapabilityProfile.

- **None** — no working passenger-cast path. Mini-apps targeting
  passenger get no cap bit. (F-series today.)
- **Fission** — standard `setLaunchDisplayId=passengerDisplayId`
  via `ActivityOptions`. Used on Di5.1 (L8, L5L, L5U) where the
  XDJA fission display delivers framework pixels. (Song PLUS is
  Di5.0 / `DishareQuickShare`, **not** Fission — corrected; L5U is
  Di5.1 / Fission.)
- **DishareQuickShare** — the working passenger-cast on Di5.0
  (L5, Song PLUS): the `DishareTransport.fastCast` binder sequence
  (`register → setVideoSize → setGestureShare → quickShare("fse")`,
  ops 1/11/9/8) after foregrounding the app on the IVI. Standard
  `setLaunchDisplayId` is silently dropped on the
  `FLAG_OWN_CONTENT_ONLY` virtuals these trims expose. (Replaced the
  removed `SyntheticSwipe` / `MultiTouchInjector` path — see
  [50/05](../../../50/05-launch-mechanisms.md).)

### `ClusterCapability`

`Pixel` / `Icons`. Set, not enum — see CapabilityProfile.

### `Powertrain`

`Ev` / `Phev` / `Erev` / `Ice` / `Unknown`. The data-shape signal
that drives mini-app UX decisions about which fields to render
(battery only / battery+fuel / fuel only). Exposed to mini-apps
via `getContext().powertrain`.

Discriminator at probe time:
`byd_content_providers.dicare_record.columns`:

- `hev_mileage` present → Phev or Erev
- `total_mileage` only with EV-related vendor_props → Ev
- fuel-only vendor_props → Ice

## Registry — `CarProfileRegistry`

```kotlin
object CarProfileRegistry {
    fun forVariant(variantId: String?): CarProfile      // O(1), Generic fallback
    fun forActiveCar(): CarProfile                       // hot path; AtomicReference
    fun setActive(variantId: String?)                    // called once at boot
    fun resetActiveForTesting()
    fun knownProfilesForTesting(): List<CarProfile>
}
```

- Three tiers: **probe-validated** trims have a real `CarProfile`
  in `ALL`; **stub** trims are derived on demand by
  `stubProfile(...)` from the `STUB_TRIMS` name map
  (`GENERIC_PROFILE` + friendly name + a `profile_source=stub`
  triage tag — no stored object); **runtime DiLink fallback** maps
  the generation token to a conservative Generic.
- `forVariant("tang")` (a stub trim) returns a Generic-shaped
  profile whose `familyName` is `"BYD Tang"` — so the Settings /
  About name and Sentry variant tag stay precise.
- `forVariant("di5.0")` / `forVariant("di5.1")` (unknown variant,
  but the detector surfaced the `ro.vehicle.type` generation token
  at the head of the model-id chain) → `GENERIC_DI50` / `GENERIC_DI51`:
  Generic shape with the generation-correct passenger transport
  (Di5.0 → DiShare, fixing the silent cast failure) and a
  **conservative empty cluster** (no unprobed cluster claims).
- `forVariant(null)` / `forVariant("unknown_trim")` (no token at
  all, neither probe-validated nor a stub name) return
  `GENERIC_PROFILE` (unchanged permissive default).
- `forActiveCar()` is lock-free reads on an `AtomicReference`.
  `ModelDetectorChannel` calls `setActive(...)` once detection
  resolves at boot.

Adding a new trim: see [`adding-a-trim.md`](adding-a-trim.md).
