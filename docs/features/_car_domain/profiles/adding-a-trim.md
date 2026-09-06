# Adding a new BYD trim — playbook

End-to-end checklist for adding support for a new BYD trim.
Every step is small; the discipline is in landing them in order
so the static profile, the runtime resolver, and the detector
agree.

## 0. Get a probe

Don't start without an on-car probe. The collector app produces
`byd-fingerprint-<outsw>-<timestamp>.json` with everything needed
to populate the static profile:

- `vehicleTypeValue` (legacy `vehicleType` key)
- `vehicle40dCode`
- `modelVariant`
- `displays[]` with each `Display.ownerPackageName`
- `cluster_transport.viableTransports`
- `dishare_transport.syntheticSwipeViable`
- `body_control` / `ac_manager` probes
- `byd_content_providers.dicare_record.columns`
- `xdja_container.anyPackagePresent`

If a field is missing, add a TODO and ship the profile with a
conservative default, and note the unknown in the definition's
KDoc header (the `triage.knownLimitations` field was removed — it
had no consumer / no Settings surface; provenance lives in the
KDoc now).

## 1. Create `definitions/<TrimName>.kt`

Pick a `variantId` (lowercase, snake_case). Mirror an existing
trim with similar topology to start:

- Di5.0 + BYD-container fission → mirror `SongPlus.kt` or
  `Leopard5.kt`
- Di5.1 + XDJA-container fission → mirror `Leopard8.kt`
- Cluster has both Pixel and Icons → mirror `Leopard5Lidar.kt`

Required header doc-comment shape:

```kotlin
/**
 * <Trim name> — <DiLink generation>, <SoC if known>, <Android version if known>.
 *
 * Sources:
 *   * Live collector probe: <probe-filename>.json
 *     (build `<outsw>` / <date>, schemaVersion <X>).
 *   * `vehicle40dCode` = "<code>" or null (not observed).
 *   * `modelVariant` = "<token>" or null (not observed).
 *
 * Display topology (<N> surfaces):
 *   <id>  <name>   <wxh> d=<density>  (<role>; owner=<pkg>)
 *
 * Capability evidence:
 *   * <field> = <value> → <consequence in profile>.
 *   * ... (one bullet per probe field that influenced the profile)
 */
// PREFER an archetype .copy() — most trims share a behavioural
// shape (see Archetypes.kt). Override identity + real deltas only:
internal val <TRIM>_PROFILE = DI51_XDJA_CLUSTER.copy(
    // ↑ or DI51_FISSION_NO_CLUSTER / DI50_BYD_DISHARE
    variantId = "<id>",
    familyName = "<UI label>",
    // ...only genuinely-empirical deltas, e.g.:
    // capabilities = DI51_XDJA_CLUSTER.capabilities.copy(
    //     cluster = setOf(ClusterCapability.Pixel)),
)

// NO archetype fits? Write a full CarProfile (promote it to a new
// archetype the moment a second trim shares the shape):
internal val <TRIM>_PROFILE = CarProfile(
    variantId = "<id>",
    familyName = "<UI label>",
    dilinkFamily = DilinkFamily.Di50,   // or Di51 / Unknown
    powertrain = Powertrain.Phev,       // Ev|Phev|Erev|Ice|Unknown
    displays = DisplayProfile(...),
    capabilities = CapabilityProfile(
        universalCaps = STANDARD_UNIVERSAL_CAPS,
        passenger = PassengerTransport.Fission, // None|Fission|DishareQuickShare
        cluster = setOf(...) or emptySet(),
    ),
)
```

The probe's `vehicle40dCode` / `modelVariant` are **documentation
provenance** (recorded in the KDoc header above), not `CarProfile`
fields — they had no consumer and were removed.

Powertrain rule of thumb (per
[`detection.md#powertrain`](runtime-profile.md#per-action-support)):
PHEV is the safe default for current BYD trims. Confirm with
`dicare_record.columns`.

## 2. Register in `CarProfileRegistry.ALL`

`CarProfileRegistry.kt`:

```kotlin
private val ALL: Map<String, CarProfile> = listOf(
    LEOPARD8_PROFILE,
    LEOPARD5_PROFILE,
    // ...
    YOUR_TRIM_PROFILE,    // ← add here
).associateBy { it.variantId!! }
```

That's all the registry needs — `forVariant(...)` and
`forActiveCar()` pick it up immediately.

> **Stub-only trim?** If you have no live probe data yet and only
> need the friendly name + telemetry (not a real profile), skip
> steps 1–2: add a single `"<variantId>" to "<Friendly Name>"`
> row to `STUB_TRIMS` instead. `stubProfile(...)` synthesizes a
> `GENERIC_PROFILE`-shaped profile with that name on demand.
> Promote it to a real `ALL` entry when a live unit surfaces.

## 3. Update the detector

`lib/platform/device/model_detector.dart`'s `_resolveModel(...)` is
keyed on the `(carType, vehicleId)` pair the BYD SDK returns.
Add a row inside the carType branch (or a vehicleId-only row when
carType reports `unknown`).

```dart
// (carType, vehicleId) — most common case (FCB family).
case 'FCBSQ':
  if (vehicleId == 155) return ('l8', 'Leopard 8');
  if (vehicleId == NEW) return ('lN', 'Leopard N');  // ← new row
  return ('fcbsq', 'FangChengBao FCBSQ');

// vehicleId-only — for trims where model_variant.model is `unknown`.
switch (vehicleId) {
  case 243: return ('song_plus', 'Song PLUS');
  case NEW: return ('newmodel', 'BYD New Model');
}

// Top-level carType — for new BYD models added to the SDK.
case 'NEWMODEL':
  return ('newmodel', 'BYD New Model');
```

Don't pattern-match raw outsw / system.model / Chinese tokens —
those are ROM-cosmetic and BYD changes them between releases.
The detector consumes the canonical signal BYD's own framework
writes, so cosmetic drift can't break detection.

Update `_kFriendlyNames` so the override path stays in sync.

## 4. Add fixture tests

Two tests, both required:

### a) Static-profile fixture

`test/.../car_profile_<trim>_test.dart`. Pin the resolved
profile shape so a future "small" change can't silently
re-route the trim:

```dart
test('Leopard 8 static profile', () {
  final profile = CarProfileRegistry.forVariant('l8');
  expect(profile.dilinkFamily, DilinkFamily.di51);
  expect(profile.capabilities.passenger, PassengerTransport.fission);
  expect(profile.displays.hiddenDisplayIds, {3, 4});
});
```

### b) Detector test

`test/core/device/model_detector_test.dart`. Pin that the trim's
`(carType, vehicleId)` pair resolves to the right variantId:

```dart
test('Leopard N — (FCBSQ, NEW) resolves to lN', () {
  final m = ModelDetector.classifyForTest({
    'carType': 'FCBSQ',
    'vehicleId': NEW,
    'dilinkRaw': 'Di5.1_5.0UI',
  });
  expect(m.variant, equals('lN'));
  expect(m.friendlyName, equals('Leopard N'));
});
```

## 5. Smoke-build and install

```bash
# Validate public assets and the existing signer
bash scripts/ci/prepare-offline-release.sh

# Build signed release
bash scripts/prepare-signing.sh
bash scripts/build-prod-apk.sh --release

# Install on device
adb -s <device-ip>:5555 install -r build/app/outputs/flutter-apk/app-release.apk
```

Verify on-device:

- pkg-launcher shows the right display labels and dim states for
  the new trim;
- Sentry events arrive tagged `car.variant=<your-id>` (the tag
  comes from the Dart detector, not the profile).

## 6. Land in one PR

Per [memory: pre-release = hard cutover, not layered], one PR
should ship:

- `definitions/<TrimName>.kt`
- `CarProfileRegistry.kt` registration
- `model_detector.dart` override
- both fixture tests
- conventional-commits message
  (`feat(profiles): add <Trim> profile + detection`)

Don't ship the static profile and the detector update in
separate PRs — between them, the trim resolves to Generic and
behaves wrong on production.

## 7. Open questions go in the doc-comment

If a field is uncertain (e.g. Song PLUS's passenger transport —
Fission vs SyntheticSwipe), document the open question in the
header KDoc with the test that would resolve it. Don't paper
over uncertainty with a guess; the next person to read the file
needs to know what's still empirical TODO.

## 8. Update the catalog

Add a row to [`catalog.md`](catalog.md) so the quick-reference
table reflects the new trim.
