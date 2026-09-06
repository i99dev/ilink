# 00 · Overview — production end state

## Goal in one sentence

Any feature the BYD framework exposes on this car becomes a single
`(catalogName) → int` entry that the UI watches reactively — with zero
per-trim curation, zero polling, and a clear seam between catalog
discovery, transport, and the consumer surface.

## The four axes

The system is judged on four axes; every architectural choice below is
graded against them.

| Axis | What it means here |
|------|--------------------|
| **Centralize** | One owner per concern. `AutoCarRegistry` owns name → (dt, key) routing. `StatusKeyCatalog` owns label → name mapping. `BydAutoFeatureIdsCatalog` owns name → int. `CarChannel` owns the bridge. `CarRegistryClient` owns Dart-side consumption. There is no fifth place to look. |
| **Scale** | Adding a feature is one row in `StatusKeyCatalog` (or zero rows — most appear in `AutoCarRegistry` automatically). The registry stays correct across DiLink ROM bumps, new BYD trims, and stripped features without any code change. |
| **Performance** | Per-tick cost on the UI thread is zero — values arrive via push. App startup pays a one-time ~2–5 s probe on first boot then ~150 ms cache restore on every subsequent boot. `readStatus()` serves entirely from in-memory state once the registry is built. |
| **Maintenance** | Four layers, one source-of-truth rule, one diagnostic dump file. A new engineer can trace a single value from CAN frame → `onPostEvent` → `InAppPushManager` → `AutoCarRegistry.Entry` → EventChannel → `featureValueProvider` in under ten minutes. |

## The end state

| Layer | Component | Responsibility |
|-------|-----------|---------------|
| **Engine (Kotlin)** | `AutoCarRegistry` | Auto-discovers every catalog name that returns a non-sentinel value on this car. Holds the live `(name, dt, key, value)` index. Subscribes to push for every entry. |
| | `BydAutoFeatureIdsCatalog` | Reflects `android.hardware.bydauto.BYDAutoFeatureIds` (and nested classes) at boot. The ~21k `name → int` map. |
| | `StatusKeyCatalog` | The legacy `label → catalog name` curated set (~30 entries — door state, AC, range, speed). Source of truth for backward compatibility. |
| | `InAppPushManager` | One `BydPushDevice` per `WARM_DT`; receives `onPostEvent` callbacks; routes by `(dt, key)`. The dispatcher for live values. |
| | `AutoFeatureService` | The composer. Owns the registry, the push manager, the watchdog, and the `readStatus` surface that the legacy dashboard widgets call. |
| | `DaemonWatchdog` | Pings the shell-UID daemon every 30 s, retries via `AdbBootstrap` after 3 consecutive failures. Set-side recovery only — push subs are app-process resident and survive daemon death. |
| | `LkvPersistence` | Last-known-value disk cache keyed by `StatusKeyCatalog.label`. Survives reboots so the UI doesn't render `--` while the registry warms. |
| **Bridge** | `CarChannel` | Method channel surface (`ilink/car`) + three event channels. Routes between Dart and the engine. |
| **SDK (Dart)** | `CarRegistryClient` | Minimal client — discovery, reactive watch, write. One app-wide instance via `carRegistryClientProvider`. |
| | `featureValueProvider` | `StreamProvider.autoDispose.family<int?, String>` — drop-in for any widget that needs one catalog value. |

## What changed to get here

The historical layout had three problems:

1. **Per-tick Binder fanout.** `readStatus` issued one `getInt` per
   status key, 30 hops every second on the HOT tier. Idle daemon CPU
   sat near 12 %.
2. **Curated catalog drift.** `StatusKey` rows in the public bundled
   textproto had to be authored by hand. ROM bumps that added or
   renamed features were invisible until someone shipped a new
   textproto.
3. **Polling on the Dart side.** Widgets polled `readStatus` at 1 Hz
   to detect value changes. Latency floor was ~250 ms.

The current shape fixes all three:

1. **Push-driven values.** `InAppPushManager` receives
   `AbsBYDAutoDevice.onPostEvent` callbacks on the framework's own
   dispatcher thread. `readStatus()` returns from in-memory
   `AutoCarRegistry.Entry.value` with zero Binder calls.
2. **Auto-discovery.** `AutoCarRegistry.build()` walks the entire
   `BydAutoFeatureIdsCatalog` (~21k entries) once at boot, probes
   each (name, dt) tuple, keeps the live ones (~9k). No per-trim
   wiring. New ROM features light up on next boot.
3. **EventChannel push to Dart.** `ilink/car/registry` forwards
   every push frame to Dart as `{name, value}`. `featureValueProvider`
   rebuilds the widget on each delta. The `readStatus` 1 Hz timer
   is gone.

## What deliberately stays

- `StatusKeyCatalog` keeps the curated label set (~30 entries). It
  exists for backward compatibility with the dashboard widgets that
  key by `door_lock` not `Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`,
  and for local state consumers which use the same labels.
  `labelToCatalog()` is the bridge between the two key spaces.
- The shell-UID daemon (`DashDaemon`) stays as the write trunk.
  Push and read are in-app; set still needs system permission and
  the daemon owns that.
- Textproto holds `fast_actions`, `unit_actions`, `units`, and
  `binder_routes` — anything with value semantics or external
  bundle metadata. See [`source-of-truth.md`](./source-of-truth.md).

## What is explicitly NOT done

- No typed per-subsystem facades on the Kotlin side
  (`AcDevice`, `BodyDevice`, …). `AutoCarRegistry` is generic by
  design — typed facades would re-introduce the per-feature curation
  cost the registry was built to eliminate.
- No EventBus, no fanout layer on the bridge. The single registry
  EventChannel is multi-consumer via `StreamController.broadcast()`
  on the Dart side.
- No re-probing in the steady state. After cache restore, values
  come live from push subscriptions. The brute-force probe runs
  only when `BydAutoFeatureIdsCatalog` signature changes (ROM bump
  or app reinstall).

## Reading order

1. This file — the shape.
2. [`engine-kotlin.md`](./engine-kotlin.md) — the discovery + dispatch.
3. [`auto-discover-math.md`](./auto-discover-math.md) — why 21k → ~9k.
4. [`bridge.md`](./bridge.md) — the wire.
5. [`dart.md`](./dart.md) — the consumer.
6. [`source-of-truth.md`](./source-of-truth.md) — adding / deleting features.
7. [`operations.md`](./operations.md) — diagnostics and recovery.
