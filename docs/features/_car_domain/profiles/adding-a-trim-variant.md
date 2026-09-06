# Adding a new BYD trim variant — runbook

When a head unit reports an unrecognised `car.bydCarType` /
`car.vehicleId` pair (or resolves no variant at all), follow this
runbook to fold the new trim into `model_detector.dart` and ship a
minor release.

The detector binds to BYD's canonical car-identity SDK
(`com.byd.car.ICarInfoManager` via reflection) with a
`persist.sys.model_variant.model` + `persist.sys.vehicle_40d_code`
sysprop fallback for user-app UIDs. The runbook below assumes both
paths are in play; you don't need to know which one a given
report came from.

## SLA

**Target:** new variant reported → fix shipped in the next minor
release. Cadence is roughly weekly today; bump if a significant
share of units is affected.

**Acceptable failure mode while waiting for the fix:** the car
falls through to `GENERIC_PROFILE`. Generic doesn't hide displays
and treats cluster as available — the worst that happens is the
picker's "Driver" override label is missing and dim-reason hints
are absent. Mini-app launches still work because
`DisplayClassifier` doesn't depend on `CarProfile` for role
decisions.

## Procedure

### 1. Read the data

The standalone app ships no hosted telemetry, so identity data is
read from the head unit itself. With the unit attached over ADB,
open the dashboard app once and read the resolved snapshot:

```bash
adb logcat -s BydCarInfo
```

The underlying system properties can also be read directly:

```bash
adb shell getprop persist.sys.vehicle_40d_code
```

For each unit you can access, capture:

- `car.bydCarType` — the canonical 21-string `VehicleCarType`
  enum (HAN / TANG / SONG / QIN / XIA / SEAL / SEALION /
  DOLPHIN / N7 / N8 / N9 / D9 / Z9 / FCBSF / FCBSQ / FCBURE /
  R1 / R2 / R3 / R4). May be null if the SDK and sysprops both
  failed.
- `car.vehicleId` — BYD's `persist.sys.vehicle_40d_code`
  integer. Distinguishes sub-trims that share a `bydCarType`
  (especially in the FangChengBao family — L5=153, L8=155, …).
- `car.brand` — DYNASTY / OCEAN / DENZA / F / R / UNKNOWN.
  Useful for context but not part of the resolution key.
- `car.dilinkFamily` — `di5.0` / `di5.1` / `unknown`.

### 2. Verify uniqueness

Before adding a new line to `_resolveModel`:

- **Search the existing table** for a colliding `(carType,
  vehicleId)` pair. If two events report the same pair but you
  expect them to be different trims, the carType is too coarse
  for the family — add a new vehicleId-keyed row inside the
  carType branch.
- **Cross-check with another live unit** if the pair looks
  ambiguous. The SDK and sysprop paths must produce the same
  pair on the same car; if they diverge, file a bug before
  shipping.
- **Wait if in doubt.** Generic profile is permissive; one more
  week of telemetry beats a confidently-wrong table entry.

### 3. Add the resolver row

Edit `lib/platform/device/model_detector.dart` `_resolveModel`:

For a new trim inside an existing carType (most common — adding
a new FangChengBao SKU):

```dart
case 'FCBSQ':
  if (vehicleId == 155) return ('l8', 'Leopard 8');
  if (vehicleId == NEW) return ('lN', 'Leopard N');  // ← new row
  return ('fcbsq', 'FangChengBao FCBSQ');
```

For a trim where `model_variant.model` reports `unknown` (BYD
sometimes does this for single-trim models — Song PLUS is the
canonical example), add a vehicleId-only row:

```dart
switch (vehicleId) {
  case 243: return ('song_plus', 'Song PLUS');
  case NEW: return ('newmodel', 'BYD New Model');  // ← new row
}
```

For a brand-new carType BYD added in a ROM update we haven't
seen yet:

```dart
case 'NEWMODEL':
  return ('newmodel', 'BYD NewModel');
```

Update `_kFriendlyNames` so the override path stays in sync:

```dart
'newmodel': 'BYD NewModel',
```

### 4. Add the CarProfile (optional but recommended)

If the trim has trim-specific behaviour (different display
topology, capability set, rate limits), create
`android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/definitions/<TrimName>.kt`
following the existing `Leopard5.kt` / `Leopard8.kt` pattern,
then register it in `CarProfileRegistry.ALL`.

If the trim behaves like an existing one or you don't have
enough data yet, **skip this step** — it falls through to
`GENERIC_PROFILE`, which is the right safe default.

### 5. Test

Add a case to `test/core/device/model_detector_test.dart`:

```dart
test('NEWMODEL + vehicleId NEW resolves to newmodel', () {
  final m = ModelDetector.classifyForTest({
    'carType': 'NEWMODEL',
    'vehicleId': NEW,
    'dilinkRaw': 'Di5.1_5.0UI',
  });
  expect(m.variant, equals('newmodel'));
  expect(m.friendlyName, equals('BYD NewModel'));
  expect(m.bydCarType, equals('NEWMODEL'));
  expect(m.vehicleId, equals(NEW));
});
```

Confirm `flutter test test/core/device/model_detector_test.dart`
passes.

### 6. Verify on device

If a real car is available:

1. Install the build with the new entry.
2. Open the dashboard app once.
3. Watch logcat:
   ```bash
   adb logcat -s BydCarInfo
   ```
   Expect a line like:
   ```
   I BydCarInfo: snapshot via sysprops: carType=NEWMODEL vehicleId=NEW …
   ```
4. Confirm the resolved variant in that same logcat output reads
   `newmodel`.

### 7. Code review

The PR must:

- Reference the device evidence that motivated the entry: head
  unit, firmware build, and the captured logcat / getprop output
  for the `(carType, vehicleId)` pair.
- Update the test suite (step 5).
- Match the existing alphabetical ordering inside each brand
  family in `_resolveModel` for reviewability.

## Why we don't pattern-match raw strings anymore

The pre-2026-05-10 detector parsed `apps.setting.product.outswver`
+ `persist.sys.byd.default_name` (Chinese token) — formats BYD
changes between ROMs without warning. A previous commit shipped a
`productSystemModel.contains('l8')` substring fallback as a
"defensive" addition; three weeks later it caused the Song Plus
regression — a string match unrelated to the trim applied the
wrong profile and hid displays the car actually exposes.

The new resolver consumes the **same canonical signal BYD's own
apps consume**: the `(carType, vehicleId)` pair from the BYD
framework. The framework writes both signals, so the SDK and
sysprop paths can't drift — and the strings BYD changes between
ROMs (outswver / system.model / vendor.device) are no longer in
the resolution path at all.

When you're tempted to "add just one more heuristic," check the
live values via `adb shell getprop persist.sys.model_variant.model`
+ `adb shell getprop persist.sys.vehicle_40d_code` — if those two
plus the carType the SDK returns can't pin the trim, no string
fallback will either.
