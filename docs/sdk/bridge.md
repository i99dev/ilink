# 02 · Bridge — `CarChannel`

The Flutter ↔ Kotlin seam. One `MethodChannel` and three `EventChannel`s,
all rooted at `ilink/car…`. File: `CarChannel.kt`.

## Channels

| Channel | Type | Direction | Purpose |
|---------|------|-----------|---------|
| `ilink/car` | MethodChannel | Dart → Kotlin (with reply) | Discrete RPC verbs — discovery, action invocation, status reads. |
| `ilink/car/registry` | EventChannel | Kotlin → Dart | Per-feature push deltas from `AutoCarRegistry.onChange`. Wire: `{name: String, value: int}`. |
| `ilink/car/status` | EventChannel | Kotlin → Dart | Legacy label-keyed status deltas — daemon diff-emit / in-app push, demultiplexed by label. Wire: `{label, value, atMs}`. |
| `ilink/car/observers` | EventChannel | Kotlin → Dart | ContentProvider observer snapshots (Phase-9). Wire: `{family, observerId, snapshot}`. |

The end-state design centres on the **first two** — the new
`registry` channel is the production push path; `status` is kept for
legacy widgets that key by label.

## The four method verbs we care about

These are the BYD-API surface; everything else on `CarChannel`
(`runAction`, `acTransact`, ContentProvider verbs, identity) is
orthogonal.

### `allFeaturesAuto` → `Map<String, int>`

Live snapshot of every catalog name the registry currently has bound
(~9k on Leopard 8). Keys are full catalog names
(`Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`,
`Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE`, …); values are the
most-recent push int.

Returns empty until `AutoCarRegistry.build()` completes. Use this
for the seed read; subscribe to `ilink/car/registry` for deltas.

### `allKnownFeatures` → `Map<String, int>`

The full framework catalog (`BydAutoFeatureIdsCatalog.byName`) — ~21k
on DiLink 5.1+. Values are the framework feature-id constants, not
runtime values. Stable across boots on the same ROM.

Use this for "list everything BYD knows about" surfaces — diagnostics
screens, capability matrices, dev-time exploration. Diff against
`allFeaturesAuto()` to find names the framework defines but this car
doesn't actually expose.

### `labelToCatalog` → `Map<String, String>`

The bridge between the legacy `StatusKey.label` key space and the
catalog-name key space the registry uses. Pulled once at SDK
construct; stable for the app lifetime.

```
{
  "door_lock":   "Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT",
  "battery_pct": "Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE",
  …
}
```

### `registryStats` → `Map<String, Object?>`

Diagnostic snapshot.

```
{
  "built":              true,           // probe complete?
  "totalEntries":       9579,           // live entries
  "pushFramesReceived": 142315          // lifetime push count
}
```

### `watchdogStats` → `Map<String, Object?>`

Daemon health.

```
{
  "pingsTotal":           1234,
  "pingsOk":              1231,
  "consecutiveFailures":  0,
  "retriesAttempted":     2,
  "retriesSucceeded":     2,
  "currentBackoffMs":     30000,
  "lastRetryAtMs":        1747000000000
}
```

## Registry EventChannel — the live wire

`ilink/car/registry` is the single push path from the framework to
Dart. Setup on `onListen`:

```kotlin
auto.registry.onChange = { name, value ->
    // EventSink.success must run on the main thread.
    // Push frames arrive on the framework's dispatcher thread, so hop.
    mainHandler.post {
        registrySink?.success(mapOf("name" to name, "value" to value))
    }
}
```

Teardown on `onCancel` clears `onChange`. Single-listener — every Dart
consumer fans out from `CarRegistryClient`'s shared
`StreamController.broadcast()`.

**Threading rules** —
- Push callbacks land on the framework's own dispatcher thread (varies
  by ROM, often `Binder:dispatch`). Never the platform thread.
- `EventSink.success` must run on the platform main thread.
- `mainHandler.post` does the hop. Every emit pays one main-thread
  scheduler tick; negligible at the observed push rates (low
  hundreds/sec peak under heavy CAN activity).

## Threading and error envelopes

- All method handlers run on the messenger's background task queue
  (`makeBackgroundTaskQueue()`). Shell I/O and Binder reflection are
  safe.
- Exceptions are caught at the handler and forwarded as
  `result.error(name, message, stack)`.
- `auto.startStatusPushStream` and `auto.stopStatusPushStream` are
  bootstrapped on a daemon-named worker thread because they include
  daemon TCP round-trips that must not block the platform thread.

## Why this surface and not something larger

The four verbs cover every consumer need cleanly:

| Need | Verb |
|------|------|
| Seed the live values | `allFeaturesAuto` |
| Enumerate what the framework knows | `allKnownFeatures` |
| Translate legacy label → name | `labelToCatalog` |
| Diagnostics | `registryStats` + `watchdogStats` |
| Real-time updates | `ilink/car/registry` EventChannel |
| Writes | `runAction` (orthogonal — textproto-driven) |

Adding per-feature methods (`getDoor`, `getAc`, …) would re-introduce
the curation cost the registry was built to remove. The single
catalog-name surface is the entire BYD API.

## Anti-patterns

- **Don't** call `readStatus()` from Dart for a single feature value —
  use `featureValueProvider(name)`. It returns the same data without
  a method-channel hop, with push-driven updates.
- **Don't** poll `allFeaturesAuto` on a timer. It's a snapshot;
  subscribe to the EventChannel.
- **Don't** attach to the EventChannel multiple times from Dart
  consumers. `CarRegistryClient` is app-singleton via
  `carRegistryClientProvider`; every other consumer reads from it.
