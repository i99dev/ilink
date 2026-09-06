# Car control (`lib/features/_car_domain/`)

The car-control surface — commands, profile, safety, support, state —
lives under `lib/features/_car_domain/`. The SDK that crosses to
Kotlin lives under `lib/sdk/car/`. This doc covers the Dart side that
sits between the two.

For the SDK and engine side (CarBridge, CarRegistryClient,
AutoCarRegistry, push pipeline) read
[`sdk/`](../../sdk).

## The rule

The `_car_domain` folder is for **car-control domain code** —
commands, per-trim profile, safety policy, vehicle support metadata,
gate-snapshot derives. The car BRIDGE (CarBridge + CarClient + brand
adapter) lives in `lib/sdk/car/`. Standard-Android integrations
(`MediaSessionManager`, `LocationManager`, `startActivity`) live
under `lib/features/<feature>/data/`, even though some share the same
Kotlin MethodChannel name.

**Why** the car-control surface is security- and hardware-sensitive;
keeping it isolated means every file under `_car_domain/` is known to
touch feature IDs, the audit log, or the safety stack. See
[`rules.md §2`](../../rules.md).

## Layout

```
lib/features/_car_domain/
├── _car_domain.dart                  barrel — re-exports the surface
├── command/
│   ├── action_ids.dart               wire-id constants mirrored on Kotlin
│   ├── command.dart                  CarCommand + CommandCategory
│   ├── command_outcome.dart          uniform result type
│   ├── registry.dart                 assembles domain fragments into one map
│   ├── radio_commands.dart           in-app player commands
│   └── status_commands.dart          car.status pseudo-action
├── domain/                           per-domain CarCommand lists
│   ├── climate.dart  comfort.dart  doors.dart  lights.dart  seats.dart  windows.dart
├── consumer/
│   └── car_consumer.dart             sealed CarConsumer (HostUiConsumer,
│                                     VoiceConsumer,
│                                     DevBenchConsumer, TunnelConsumer,
│                                     MiniAppStandardConsumer, MiniAppAdminConsumer)
├── router/
│   └── command_router.dart           CarCommandRouter.dispatch
│                                     (integrity / profile / rate-limit /
│                                      stationary / registry → bridge)
├── profile/
│   ├── car_profile.dart              per-trim CarActionSupport map
│   ├── car_profile_provider.dart     CarProfileSnapshot + boot fingerprint
│   ├── car_profile_native_bridge.dart  reflects HU identity from Kotlin
│   ├── profile_key.dart              (dilink_family, sub_trim, fingerprint)
│   └── vehicle_capability.dart       display.list bits
├── safety/
│   ├── rate_limiter.dart             token-bucket per RateClass
│   ├── security_bridge.dart          audit-log + integrity probe
│   ├── integrity_health_provider.dart  StreamProvider<bool> for the UI banner
│   └── tamper_telemetry_uploader.dart  drains Kotlin-side tamper outbox
├── state/
│   ├── gate.dart                     typed snapshot type (CarGate)
│   ├── gate_snapshot.dart            push-driven `gateSnapshotProvider`
│   ├── predicates.dart               shouldEmitCarStatusDelta
│   └── gear_state_provider.dart      reactive GearPosition derived from SDK
├── support/                          vehicle support metadata
│   ├── car_support_profile.dart      car_support_profile_provider.dart
│   ├── car_support_registry.dart     hu_vendor.dart  hu_vendor_detector.dart
│   ├── integration_tier.dart         known_quirk.dart
└── ui/                               support badges + quirk chips
    └── action_quirk_chip.dart  vehicle_support_badge.dart  …
```

**Always** import via the barrel:

```dart
import 'package:ilink/features/_car_domain/_car_domain.dart';
```

Deep imports like `lib/features/_car_domain/router/command_router.dart` are internal plumbing.

## `CarCommand` wiring (one namespace)

A user-addressable command is a `CarCommand`. Per the methodology
([command source of truth](../../sdk/source-of-truth.md))
the registry id IS the wire id — no aliases, no rename tables. The
textproto under `android/app/src/main/assets/offline/car_table.textproto` is the only place an
action_id is declared; `CarCommand` carries UI metadata keyed by that
id.

### The three command shapes

Post-Phase-4 (May 2026), each `domain/<X>.dart` file consciously picks
ONE of three shapes, chosen by what the underlying wire exposes. The
file's top-level docstring states which pattern and why.

| Shape | When to use | Example |
|---|---|---|
| **`bydCatalogCommands()` overlay** | 1:1 read-state ↔ write-action signal. Catalog already has a `_Sig` row with a `wireActionId`. | `climate.dart`, `seats.dart`, `lights.dart` |
| **bare-const + Phase-2 identity** | Pure write trigger with no useful read-state counterpart (or 1:N where the catalog models the per-state read but the wire is bulk-only). Registry id IS the textproto action_id; no `resolve:`. | `doors.dart`, parts of `lights.dart`, `comfort.frag.on/off` |
| **helper or `resolve:` closure** | N voice/registry ids → 1 parameterised wire action. The helper closes over the (pos, verb) → value mapping; the resolve closure picks the action_id from `args`. | `windows.dart` (`_winCmd(pos, verb)`), `comfort.dart` (`comfort.massage`, `comfort.atmos`) |

There is no "right pattern" — there is the pattern that matches the
wire surface for that command. Forcing a 1:N wire through the
catalog builder makes the file harder to read. Reading any
`domain/<X>.dart` file's docstring tells you which pattern that file
uses and why the others don't fit.

### Catalog metadata flags

Catalog entries (`_Sig` in `byd_catalog.dart`) carry two flags that
the parity tests interpret:

- `writeable: true` — the catalog claims a mini-app or registry can
  write this signal.
- `binderOnly: true` — `writeable: true` but the write transport is
  Android binder, `acTransact`, or a `unit_actions` interpreter
  inside the daemon (NOT a `fast_actions { action_id }` row).
  Examples: `lock_lf/rf/lr/rr` (per-door state mirrors; bulk-only
  wire write), `seat_vent_pass` (IAcSeat binder), `audio_master_volume`
  / `audio_mute` (Android AudioManager).

The reverse parity test (see Enforcement below) uses `binderOnly` to
distinguish "expected to lack a wireActionId" from "Phase-3 backfill
TODO".

### Example — bare-const command

```dart
CarCommand(
  id: 'door.lock',                      // same as textproto action_id
  label: 'LOCK',
  icon: Icons.lock_rounded,
  color: AppColors.primary,
  category: CommandCategory.door,
  voiceDescription: 'Lock the doors.',
)
```

### Example — catalog-driven overlay

```dart
// climate.dart (excerpt)
final List<CarCommand> climateCommands = [
  ...bydCatalogCommands(
    category: CommandCategory.climate,
    reversible: true,
    overlays: const {
      'ac_power': CommandOverlay(
        icon: Icons.power_settings_new_rounded,
        color: AppColors.accent,
      ),
      'ac_target_temp': CommandOverlay(
        icon: Icons.thermostat,
        color: AppColors.accent,
        paramDefaultsOverride: {'value': 22}, // legacy default
        voiceDescription: 'Set cabin temperature in °C (range 16-32). ...',
      ),
      // ...one overlay row per catalog signal
    },
  ),
];
```

The overlay key (`ac_power`, `ac_target_temp`) is the catalog `_Sig`
name. The builder throws a `StateError` at build time if the key
doesn't exist in the catalog OR if the matched catalog entry lacks a
`wireActionId` — drift fails the build.

All UI surfaces (QuickActionsGrid, FeatureRail, voice tools, tunnel
dispatch) resolve commands through the same `commandRegistryProvider`
in `lib/features/_car_domain/command/registry.dart`. Adding a new
command in any `domain/<X>.dart` file propagates automatically.

## Adding an actuator (worked example)

The recipe is different depending on which of the three shapes the new
command needs. **Read the existing file in `domain/<X>.dart` first** —
its docstring tells you which shape that domain uses.

### Recipe A — 1:1 catalog signal (climate, seats, lights)

Adding `seat.fold.drv` to `seats.dart`:

**1. Textproto row** in
`android/app/src/main/assets/offline/car_table.textproto`:

```textproto
fast_actions {
  action_id: "seat.fold.drv"
  device_type: 1023        # DT_SETTING
  feature_name: "Setting.SEAT_FOLD_DRV"
  value { arg_bool { arg_name: "on" on_value: 1 off_value: 0 } }
  rate_class: RATE_CLASS_ACTUATOR
}
```

**2. Catalog row** in `lib/sdk/brands/byd/byd_catalog.dart`:

```dart
_Sig(
  'seat_fold_drv',
  'Setting.SEAT_FOLD_DRV',
  description: 'Driver seat fold (0 unfolded, 1 folded)',
  writeable: true,
  writeAction: 'seat.fold.drv',
  wireActionId: 'seat.fold.drv',
),
```

**3. Overlay entry** in `lib/features/_car_domain/domain/seats.dart`,
inside the `bydCatalogCommands(...)` call:

```dart
'seat_fold_drv': CommandOverlay(
  icon: Icons.event_seat,
  color: AppColors.accent,
  voiceDescription: 'Fold the driver seat (bool).',
),
```

Rebuild the APK to package the edited public textproto. UnitDispatcher loads it locally on the next launch.

### Recipe B — Pure write trigger (doors, light momentary)

For commands with no useful read-state counterpart (`door.lock`,
`hood.open`, `light.flash`):

**1. Textproto row** — same as Recipe A step 1.

**2. Bare-const `CarCommand`** in the right `domain/<X>.dart`:

```dart
const CarCommand(
  id: 'seat.fold.drv',                  // == textproto action_id
  label: 'FOLD DRIVER SEAT',
  icon: Icons.event_seat,
  color: AppColors.accent,
  category: CommandCategory.comfort,
  voiceDescription: 'Fold the driver seat (bool).',
),
```

**3. (Optional) Add the action_id to the reverse-parity exempt set**
in `test/sdk/brands/byd/byd_catalog_wire_parity_test.dart` with a
category comment, OR add a catalog `_Sig` row mirroring it for read
state (preferred if the wire has a state to mirror).

### Recipe C — Parameterised dispatch (windows, comfort.massage / atmos)

If the wire has one action per pane/seat with a `value` enum, or one
action per (seat, field) combination, see the existing patterns in
`windows.dart` (`_winCmd` helper) and `comfort.dart` (`resolve:`
closures). These are 1:N shapes — don't try to force them through the
catalog builder.

### Optional steps for any recipe

- **Localized label** — add a case to `lib/kernel/i18n/command_labels.dart`.
- **Wire-id constant** — add `seatFoldDrv = 'seat.fold.drv'` to
  `lib/features/_car_domain/command/action_ids.dart` and its Kotlin
  mirror. Only needed when the id is referenced from voice tool code
  or local workflow handlers; pure UI doesn't need it.

Done. CI catches mistakes:

- `registry_wire_parity_test.dart` — every `CarCommand.id` must
  resolve to a textproto wire id.
- `byd_catalog_wire_parity_test.dart` — three checks:
  1. Forward: every catalog `wireActionId` resolves to a textproto id.
  2. TODO bucket: writeable non-binderOnly signals without a
     `wireActionId` are flagged.
  3. Reverse: every textproto action_id has a catalog entry pointing
     at it OR is in the documented exempt set.
- `catalog_command_builder_test.dart` — builder throws on drift
  (unknown overlay key, missing `wireActionId`).
- `action_ids_contract_test.dart` — `ActionIds` constants 1:1
  parity with Kotlin `ActionIds.kt`.
- `forbidden_strings_test` — fails if a hex feature ID lands in
  Dart/Kotlin source (the public command table is the source of truth).
- `voice_group_consistency_test` — voice groupings consistent
  per command.

## Dispatching from the UI

```dart
final client = ref.read(carClientProvider);
await client.dispatch(
  'door.lock',
  caller: HostUiConsumer.instance,
);
```

`CarClient.dispatch` forwards to the app-injected GatedDispatcher
(see `lib/sdk/car/gated_dispatcher.dart`) which routes through
`CarCommandRouter.dispatch`. The router runs integrity → profile →
rate-limit → stationary → registry-lookup → bridge.runAction. Every
call is audited via `SecurityBridge.logDispatch`.

For UI-state reads (climate target temp, lock state, etc.) use
`featureValueProvider(name)`:

```dart
final lock = ref.watch(featureValueProvider(
  'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
));
```

Don't poll. Don't call `bridge.readStatus()` directly. The SDK's
push-driven cache is the only authorised read path.

## Two-path domains (seats today)

Seat heat/vent has **two transports** routed through the same
controller depending on trim:

| Route | Wire id pattern | Notes |
|---|---|---|
| UNIT path | `seat.heat.{drv,pass,rl,rr}`, `seat.vent.drv` | `BYDAutoManager` feature keys via `seatheatventunit.dex`. Broadest compatibility — the Leopard 8 only has these. |
| AC-binder path | `seat.vent.{pass,rl,rr}` | `IAcSeatVentilationHeating` via `acTransact("seat", "set", …)`. Trim-dependent — null service on cars without ventilated rear seats. |

Not grouped for voice because the failure modes differ: the binder
variants return typed failures when the service is absent; the UNIT
variants return `65535` (inactive). See [`rules.md §8`](../../rules.md).

## Universal pipeline — one chain, every caller

```
caller (UI / voice / mini-app / tunnel / dev bench)
  → client.dispatch(actionId, caller: CarConsumer)
    → GatedDispatcher (sdk/car/gated_dispatcher.dart)
      → CarCommandRouter.dispatch
        → integrity gate / profile fast-deny / rate limit / stationary
        → registry[actionId]
        → bridge.runAction
          → MethodChannel ilink/car → Kotlin UnitDispatcher
            → EncryptedCarTableSource.fastAction(id) / unitAction(id)
              → AdbShellBridge.fastSet → DashDaemon → BYD framework
```

Audit logs distinguish callers via `CarConsumer.kindLabel`. The path
itself is identical for every entry point — the typed caller is the
only difference.

## Enforcement

```bash
flutter test test/architecture/layer_test.dart                          # layer direction
flutter test test/core/car/commands/registry_wire_parity_test.dart      # registry ↔ wire id
flutter test test/sdk/brands/byd/byd_catalog_wire_parity_test.dart      # catalog ↔ wire id (forward + reverse + TODO bucket)
flutter test test/features/_car_domain/command/catalog_command_builder_test.dart  # builder drift detection
flutter test test/core/car/commands/action_ids_contract_test.dart       # Dart ↔ Kotlin ActionIds
```

All CI-blocking. Together they triple-lock the bridge:

- **registry ↔ wire** — every `CarCommand.id` is a textproto action_id.
- **catalog ↔ wire forward** — every catalog `wireActionId` is a textproto action_id.
- **catalog ↔ wire reverse** — every textproto action_id is either
  mirrored in the catalog or in the documented exempt set.
- **builder drift** — `bydCatalogCommands()` throws on unknown overlay key
  or missing `wireActionId`.

See [command source of truth](../../sdk/source-of-truth.md) for the current public-table and registry contract.
