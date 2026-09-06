# Identity — brand × firmware × model × sub-trim × fingerprint

The SDK publishes a single typed identity for the connected vehicle.
Every consumer (UI gating, voice tool dispatch, mini-app fan-out,
local state consumers) reads from it instead of re-deriving from build.prop or
reflecting on the framework class.

## The 5-axis key

```dart
class ProfileKey {
  CarBrand brand;             // .byd / .geely / .nio / .tesla / .unknown
  String   firmwareVersion;   // 'dilink_5_0' / 'dilink_5_1' / 'dilink_8_x'
  String   modelName;         // 'l5' / 'l8' / 'han' / …
  String?  subTrim;           // 'flagship' / 'navigator' / 'ultra'
  String   fingerprint;       // build.prop hash for ambiguous cases
}
```

**Why 5-axis** — two adapters can share the same hardware trim but
behave differently because of the framework version they run against
(canonical case: BYD DiLink 5.0 vs 5.1 register push callbacks
differently). Encoding `firmwareVersion` as a first-class axis lets
routing pick the right adapter without leaking version checks into
call sites.

### Wire compatibility

The JSON shape sent across the platform channel still uses
the legacy field names `dilinkFamily` (= `firmwareVersion`) and
`variantId` (= `modelName`) so existing Kotlin compatibility code keeps
working. `ProfileKey.dilinkFamily` and `.variantId` are back-compat
getters on the Dart side; new code reads `firmwareVersion` +
`modelName`.

## The contract surface

```
sdk/car/identity/
├── car_identity.dart           CarIdentity — runtime snapshot
├── car_profile.dart            CarProfile + CarActionSupport
├── profile_key.dart            the 5-axis key
├── vehicle_capability.dart     display.list bit positions
└── car_identity_provider.dart  Riverpod surface
```

`CarClient` exposes both:

```dart
abstract class CarClient {
  CarIdentity     get identity;       // who am I talking to?
  CarCapabilities get capabilities;   // what does it support?
}
```

Brand-specific implementations live under `sdk/brands/<brand>/identity/`.
Today's BYD shape:

```
sdk/brands/byd/identity/
└── byd_model_detector.dart   build.prop + ICarInfoManager reflection
```

## DiLink adapter pattern (BYD-specific)

When a brand has fundamentally different code paths per firmware
version, it ships **one adapter file per version**. The adapter
encapsulates version-specific behaviour as flags + asset paths so the
rest of the brand code reads them through a final field.

```
sdk/brands/byd/dilink/
├── byd_dilink_adapter.dart    abstract — chooses 5.0 / 5.1 / 8.x at boot
├── byd_dilink_5_0.dart        first-gen ROMs
├── byd_dilink_5_1.dart        dominant 2024H2+ ROMs (default)
├── byd_dilink_8_x.dart        Leopard 8 + Yangwang with cluster signing
├── byd_dilink_unknown.dart    conservative fallback
└── dilink.dart                barrel + registration
```

### What the adapter knows

```dart
abstract class BydDilinkAdapter {
  DilinkVersion get version;
  String?       get assetBundleDir;            // → assets/byd/<dir>/...
  bool          get pushRequiresAppContext;    // 5.1+ truthy
  bool          get clusterPixelSignatureGated; // 8.x truthy
}
```

### Why flags-not-branches

`BydClient` constructs once and stores the chosen adapter in a final
field. Hot-path reads (push registration decision, cluster-pixel
write decision, asset path) are single field accesses — no per-call
switch.

```dart
class BydClient {
  final BydDilinkAdapter dilink;   // chosen once at construct
  BydClient(Ref ref) : dilink = BydDilinkAdapter.detect();
}

// caller, anywhere
if (client.dilink.clusterPixelSignatureGated) return skip();
```

### Adding a new DiLink version

1. Add an enum entry to `DilinkVersion` (`dilink_5_2` etc.).
2. Add `byd_dilink_5_2.dart` extending `BydDilinkAdapter`.
3. Register in `dilink.dart`'s `ensureBydDilinkAdaptersRegistered()`
   map.
4. Wire detection in `byd_dilink_adapter.dart::_probeFromFramework()`.
5. (Optional) ship `assets/byd/dilink_5_2/car_table.pb.enc` if the
   action table diverges. Otherwise the shared default applies.
6. The readiness test
   (`test/sdk/brands/byd/dilink/byd_dilink_adapter_test.dart`)
   exercises every enum entry — it fails specifically when a new
   version isn't registered.

## Firmware-versioned encrypted assets

Kotlin's `EncryptedCarTableSource` consults a system property
(`ilink.byd.dilink_variant`) before falling back to the shared
default. When the Dart side detects DiLink 5.0 or 8.x and the CI
pipeline ships `assets/byd/<version>/car_table.pb.enc`, that variant
is loaded; otherwise the shared `assets/car_table.pb.enc` stays the
source of truth.

This means:

- **Today:** all ROMs use the shared default. No behaviour change.
- **Tomorrow:** if Leopard 8 needs a 5-key tweak, ship
  `assets/byd/dilink_8_x/car_table.pb.enc` — Leopard 8 picks it up;
  every other trim keeps using the shared bundle.

## CI gates

| Test | What it pins |
|------|--------------|
| `test/architecture/layer_test.dart` | SDK has zero outward imports. |
| `test/sdk/car/identity/profile_key_test.dart` | 5-axis key contract, wire round-trip, back-compat getters. |
| `test/sdk/brands/byd/dilink/byd_dilink_adapter_test.dart` | Every `DilinkVersion` registered + policy flags self-consistent. |

## Adding a new brand

```
sdk/brands/geely/
├── geely_client.dart                  implements CarClient
├── identity/
│   ├── geely_model_detector.dart       Geely-specific HU detection
│   └── geely_profile_database.dart     per-trim CarActionSupport map
└── (if firmware-versioned)
    firmware/
    ├── geely_firmware_adapter.dart    abstract
    ├── geely_firmware_<v1>.dart
    └── geely_firmware_<v2>.dart
```

Plus a readiness test mirroring the BYD one. Zero churn in
`features/`, `kernel/`, `platform/`, or `app/`.

## Related docs

- [`README.md`](./README.md) — SDK boundary overview.
- [`overview.md`](./overview.md) — production end-state of the car SDK.
- [`bridge.md`](./bridge.md) — method + event channel surface.
- [`source-of-truth.md`](./source-of-truth.md) — what lives in Kotlin vs textproto.
