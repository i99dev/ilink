# Derived features

Computed signals that auto-recompute whenever their inputs change.
Surfaces through the same `value` / `watch` / `freshness` API as
native push-fed features — consumers don't know the difference.

## When to use

You're building a tile that combines two or more catalog signals. The
classic case: "any door open" = OR of five door states. Without
derives you'd subscribe to all five, recompute on every rebuild, and
duplicate that logic across every consumer that needs it.

With derives you register the computation once on `CarClient`. Any
widget can `ref.watchFeatureInt('derived.any_door_open')` and get the
result reactively.

## API

```dart
abstract class CarClient {
  DerivedHandle derive({
    required String name,
    required List<String> sources,
    required int? Function(Map<String, int?> sources) compute,
  });
}
```

- **`name`** — namespace your derives under `derived.<...>` so they
  don't collide with framework catalog names. Convention, not
  enforced.
- **`sources`** — list of catalog names whose pushes trigger
  recompute. The SDK auto-subscribes them so the derive sees pushes
  even if no widget watches the source directly.
- **`compute`** — pure function from `{source-name: int?}` to the
  derived value (or `null` to remove). Called eagerly on register
  AND on every source push.

Returns a `DerivedHandle` — call `dispose()` to unregister and clear
the derived value from the cache.

## Recipes

### Any door open
```dart
final handle = client.derive(
  name: 'derived.any_door_open',
  sources: const [
    'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
    'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR',
    'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR',
    'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR',
    'Bodywork.BODYWORK_LUGGAGE_DOOR',
  ],
  compute: (vals) => vals.values.any((v) => v == 1) ? 1 : 0,
);
// later, in a tile:
final anyOpen = ref.watchFeatureInt('derived.any_door_open');
```

### Headlights state (head-on OR low-beam OR high-beam)
```dart
client.derive(
  name: 'derived.lights_on',
  sources: const [
    'Light.LIGHT_LOW_BEAM_LIGHT',
    'Light.LIGHT_HIGH_BEAM_LIGHT',
    'Light.LIGHT_FRONT_FOG_LIGHT',
    'Light.LIGHT_REAR_FOG_LIGHT',
  ],
  compute: (vals) => vals.values.any((v) => v == 1) ? 1 : 0,
);
```

### Total range (EV + fuel)
```dart
client.derive(
  name: 'derived.total_range_km',
  sources: const [
    'Statistic.STATISTIC_ELEC_DRIVING_RANGE',
    'Statistic.STATISTIC_FUEL_DRIVING_RANGE',
  ],
  compute: (vals) {
    final ev = vals['Statistic.STATISTIC_ELEC_DRIVING_RANGE'] ?? 0;
    final fuel = vals['Statistic.STATISTIC_FUEL_DRIVING_RANGE'] ?? 0;
    return ev + fuel;
  },
);
```

### Cabin "comfortable" boolean
```dart
client.derive(
  name: 'derived.cabin_comfortable',
  sources: const ['Ac.AC_TEMP_INSIDE'],
  compute: (vals) {
    final t = vals['Ac.AC_TEMP_INSIDE'];
    if (t == null) return null;          // unknown
    return (t >= 18 && t <= 26) ? 1 : 0;
  },
);
```

## Lifecycle

- Register derives **once** at app startup (or whenever the deriving
  surface mounts). A common spot: a top-level provider that wires
  every brand-agnostic derive in one place.
- Re-registering the same `name` replaces the prior compute — useful
  if your inputs change at runtime (different trim, different feature
  flags).
- Always store the `DerivedHandle` and `dispose()` it when the
  registering surface goes away. The SDK keeps the derived value in
  the hot cache + push pipeline until you do.

## Performance notes

- Compute fires on every push frame for any source. If your function
  is pure (recommended) and constant-time over its inputs (the usual
  case for OR / SUM / range checks), this is free.
- Derives can't currently depend on other derives. If you need a
  multi-stage compute, materialize the intermediate values yourself
  in a single `compute` fn.
- Derives don't go to the daemon. Their freshness is the **most
  recent of any source's** freshness — the SDK stamps
  `_lastUpdateAt[name]` to `now()` whenever the compute runs.

## What's NOT supported

- **Async compute** — keep it pure synchronous. Hop to a `Future` in
  the consumer if you need an async transform.
- **Non-int values** — derives produce `int?` (matches the rest of
  the SDK). Booleans use 0/1; enums use the underlying int.
- **Cross-brand derives in `lib/sdk/brands/`** — derives belong in
  the consumer's domain code, not in a brand adapter. The brand
  adapter exposes raw signals; the consumer composes them.
