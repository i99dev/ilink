# 03 · Dart SDK — `CarRegistryClient` + `featureValueProvider`

The minimal Dart consumer surface. Two classes; ~200 lines combined.
File: `lib/sdk/car/car_registry_client.dart`.

## The whole surface

```dart
final api = ref.watch(carRegistryClientProvider);

// Discovery
final all = await api.liveFeatures();     // Map<String, int>  ~9k
final names = await api.allCatalogNames();// Iterable<String>  ~21k

// Reactive watch
final lock = ref.watch(featureValueProvider(
  'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
));
// lock is AsyncValue<int?> — emits seed value, then on every push

// Sync read (use sparingly)
final v = api.value('Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE');

// Write
await api.invoke('door.lock');
final ok = await api.invokeOk('ac.power_on');
```

That is the entire API. There are no typed facades, no permission
scopes, no value semantics layered on top. Consumers that want
"`lock` is `1` ⇒ locked, `2` ⇒ unlocked" map that themselves at
their own seam.

## `CarRegistryClient`

```dart
class CarRegistryClient {
  CarRegistryClient(this._transport) { _attachPushStream(); }

  final CarTransport _transport;
  final _values   = <String, int>{};
  final _watchers = <String, StreamController<int?>>{};

  Future<Iterable<String>> allCatalogNames();
  Future<Map<String, int>> liveFeatures();
  Stream<int?>             watch(String name);
  int?                     value(String name);
  Future<Map<String, Object?>> invoke(String actionId, [Map args = const {}]);
  Future<bool>             invokeOk(String actionId, [Map args = const {}]);
  Future<List<String>>     knownActions();
  Future<void>             dispose();
}
```

### Lifecycle

- `_attachPushStream` runs in the constructor — one
  `EventChannel('ilink/car/registry').receiveBroadcastStream()`
  subscription. Every event arrives as `{name, value}`; we update
  `_values[name]` and forward to `_watchers[name]?.add(value)`.
- Lazy seed — first call to `liveFeatures()` or `watch()` triggers
  `_seed()`, which calls `allFeaturesAuto()` and merges (without
  overwriting any value that arrived via push during the seed
  window).
- The seed is **idempotent + race-safe** — concurrent callers share
  the same `_seedingFuture`.

### Watch semantics

```dart
Stream<int?> watch(String name) async* {
  await _ensureSeeded();
  final ctl = _watchers.putIfAbsent(
    name, () => StreamController<int?>.broadcast());
  yield _values[name];   // immediate seed value (null if never seen)
  yield* ctl.stream;     // then every push frame
}
```

- Always emits an immediate value (the cached one, or `null`).
- Then every push frame for that name.
- Broadcast controller — multiple `featureValueProvider` consumers
  for the same name share the same upstream.

### Write surface

Writes go through `runAction(actionId, args)`. The action id is one
of the textproto-defined `fast_actions` or `unit_actions`. The host
reply is `{ok: true}` on success, `{error: ..., code: ...}` otherwise.

```dart
final ok = await api.invokeOk('door.lock');
final r  = await api.invoke('ac.set_temp', {'temp': 22});
```

`knownActions()` enumerates fast + unit ids; useful for dev tools
and command palettes.

## `featureValueProvider`

```dart
final featureValueProvider =
    StreamProvider.autoDispose.family<int?, String>((ref, name) {
  final client = ref.watch(carRegistryClientProvider);
  return client.watch(name);
});
```

- `autoDispose` — when no widget watches a name, its controller
  drops (the upstream EventChannel sub is shared, so it stays).
- `family<int?, String>` — keyed by catalog name.
- Returns `AsyncValue<int?>` — `whenData` for the value path.

### Idiomatic usage

```dart
class LockIcon extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(featureValueProvider(
      'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
    ));
    return v.when(
      data:    (n) => Icon(n == 1 ? Icons.lock : Icons.lock_open),
      loading: () => const Icon(Icons.lock_outline),
      error:   (_, __) => const Icon(Icons.error_outline),
    );
  }
}
```

## App-wide singleton

```dart
final carRegistryClientProvider = Provider<CarRegistryClient>((ref) {
  final c = CarRegistryClient(ref.watch(carBridgeProvider));
  ref.onDispose(c.dispose);
  return c;
});
```

One `CarRegistryClient` per app. One `EventChannel` subscription.
Every consumer fans out from the per-name broadcast controllers.
This is the centralization rule for the Dart side — there should
not be a second push subscriber.

## What `CarRegistryClient` deliberately does NOT do

- **No typed value semantics.** It returns `int?`. If a feature
  encodes "1 = on, 2 = off, 3 = auto", that mapping lives in the
  widget or in a small domain helper next to the widget — not here.
- **No write-side validation.** `invoke(actionId)` forwards verbatim.
  The host does its own validation; the client surfaces whatever the
  host says.
- **No backwards-compatibility shims for `label` keys.** Use
  `labelToCatalog()` once at construct if you need to bridge a
  legacy label-keyed consumer.
- **No batched watches.** If a widget needs 10 features, it watches
  10 providers. The broadcast controllers are cheap; Riverpod's
  reactivity is the right granularity.

## Migration from the legacy `readStatus` path

Old:

```dart
final status = ref.watch(carStatusStreamProvider);
final v = status.value?['door_lock'];
```

New:

```dart
final v = ref.watch(featureValueProvider(
  'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
));
```

The legacy provider polls `readStatus()` at 1 Hz; the new one is
push-driven (latency ~30–50 ms p99). Migrate widgets at their own
pace — both paths share the same underlying values via
`AutoFeatureService.readStatus`'s registry fast-path.
