# Add a feature to a tile

You want a new value on the dashboard or in a mini-app. This page is
the recipe — under 10 minutes start to first paint.

## Scenario

Say a designer wants the Trunk tile to show whether the rear window is
open or closed. The catalog name is `Bodywork.BODYWORK_REAR_WINDOW` (or
whatever the BYD framework actually exposes — check the gate probe).

## Step 1 — find the catalog name

Two ways:

```
# A) Look at what the SDK already lists
lib/sdk/brands/byd/byd_status_labels.dart  # bydStatusLabelToCatalog

# B) Live-discover via the gate-probe screen
adb -s <device> shell monkey -p com.i99dev.ilink -c android.intent.category.LAUNCHER 1
# Settings → Diagnostics → Gate probe — search the list, every live name is green
```

If the name isn't in the SDK label map AND isn't green on the gate
probe, the framework doesn't expose it on this trim. Pick a different
signal or capture a fresh dump
(`docs/features/_car_domain/feature-ids/dump.sh <trim>` — see [`../features/_car_domain/feature-ids/README.md`](source-of-truth.md)).

## Step 2 — read it from the widget

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ilink/sdk/car/widget_helpers.dart';

class TrunkTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rearWindow = ref.watchFeatureInt('Bodywork.BODYWORK_REAR_WINDOW');
    return Text(rearWindow == 1 ? 'OPEN' : 'closed');
  }
}
```

That's it.

- `watchFeatureInt(name)` returns `int?` — null until the first value
  arrives (typically <100 ms).
- The widget rebuilds automatically on every push frame (~200 ms
  cadence on hot signals).
- No subscribe / unsubscribe lifecycle to manage. Side-effect of
  reading is registering a daemon-poll sub; the SDK dedupes.

## Step 3 — (optional) add to the boot warm set

If the value matters on first paint, add the catalog name to
`bydBootWarmSet` in `lib/sdk/brands/byd/byd_status_labels.dart`:

```dart
const List<String> bydBootWarmSet = [
  // ... existing ...
  'Bodywork.BODYWORK_REAR_WINDOW',
];
```

The SDK fetches every name in this set in one batched daemon call at
boot, so no widget paints "loading…" for it.

Without this step, the first read happens lazily on the widget's
first build (~30 ms extra latency on the first frame; fine for
non-critical widgets).

## Step 4 — (optional) typed alias in the gate snapshot

If voice / mini-apps need a typed accessor (not just
`ref.watchFeatureInt('...')`), add it to the `CarGate` class in
`lib/features/_car_domain/state/gate.dart`:

```dart
class CarGate {
  // ...
  final int? rearWindow;
  // ...
}
```

Then map it in `lib/sdk/car/gate_snapshot.dart`'s `_buildGate` so the
gate-snapshot stream emits it. After that, `ref.watch(gateSnapshotProvider)`
exposes `gate.rearWindow` as a typed field.

Most tiles don't need this — `watchFeatureInt(name)` is the simpler
path.

## Voice tool reading car state

```dart
class WindowTool {
  Future<String> isRearOpen(WidgetRef ref) async {
    final v = ref.read(carClientProvider).value('Bodywork.BODYWORK_REAR_WINDOW');
    return v == 1 ? 'open' : 'closed';
  }
}
```

`ref.read(carClientProvider).value(name)` is the synchronous one-shot
read. Returns whatever's in the cache (null if never seen). For voice
tools the latency tolerance is high enough that a synchronous read is
the right shape.

## Mini-app reading car state

Mini-apps don't get a direct SDK reference. They subscribe via the JS
bridge:

```js
window.ilink.car.status.subscribe((snapshot) => {
  console.log(snapshot.rearWindow);
});
```

The host's `CarStatusFanout` singleton watches `gateSnapshotProvider`
and broadcasts to every viewer with a throttle bucket. New fields show
up in the JS payload as soon as they're added to the gate snapshot
(step 4 above) — the bridge is field-by-field projection, no manual
plumbing.

## Writing to the car (commands)

Reads use the SDK; writes use `carCommandRouterProvider`:

```dart
final router = ref.read(carCommandRouterProvider);
await router.dispatch('door.lock', const {});
```

Dispatch IDs live in the bundled public textproto (source-of-truth:
`android/app/src/main/assets/offline/car_table.textproto`). Adding a write target is a
separate workflow — see [`../features/_car_domain/README.md`](README.md).

## Common derives (free, no setup)

`BydClient` auto-installs a handful of cross-cutting derived signals
on construct — every consumer can read them via `watchFeatureInt`
without registering anything:

| Derived name                       | Equivalent rule |
|------------------------------------|-----------------|
| `derived.any_door_open`            | OR of 4 doors + trunk |
| `derived.exterior_lights_on`       | OR of low-beam, high-beam, fog F/R |
| `derived.total_range_km`           | EV range + fuel range |
| `derived.cabin_comfortable`        | `Ac.AC_TEMP_INSIDE` ∈ [18, 26] °C |
| `derived.driver_door_open`         | front-left door state, normalised to 0/1 |

Source: `lib/sdk/brands/byd/byd_common_derives.dart`. Add a new common
derive there and every consumer gets it next launch — no per-tile
registration. Custom one-off derives (a tile-specific composition not
worth promoting) still use `client.derive(...)` inline; see
[`derived-features.md`](./derived-features.md).

## Things you DO NOT need to do

- Subscribe / unsubscribe — `watchFeatureInt` does that.
- Throttle — the daemon polls at 200 ms; we never get a frame faster
  than the diff loop emits it.
- Translate raw daemon JSON — the SDK has already typed it.
- Touch `featureValueProvider / gateSnapshotProvider (see sdk/)` — that provider is gone. If you see code
  importing it, it's stale; replace with `gateSnapshotProvider` (typed
  snapshot) or `watchFeatureInt(name)` (per-name).
- Worry about which device-type a name lives on — the host probes
  once and persists.
