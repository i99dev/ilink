# 01 · Engine (Kotlin) — discovery + dispatch

Everything in `android/app/src/main/kotlin/com/i99dev/ilink/car/` plus
`daemon/DaemonWatchdog.kt`. This is the layer that talks to the BYD
framework directly.

## Component map

```
┌──────────────────────────────────────────────────────────────────┐
│ AutoFeatureService    (init-on-CarChannel-construct)             │
│                                                                  │
│   ├── inAppPush: InAppPushManager                                │
│   │     ├── BydPushDevice × WARM_DT (1000, 1001, 1023, 1038,     │
│   │     │                            1040, 1041, 1045)           │
│   │     └── sink: (dt, key, value) → subs[(dt,key)].dispatch     │
│   │                                                              │
│   ├── registry: AutoCarRegistry                                  │
│   │     ├── catalog source: BydAutoFeatureIdsCatalog.byName      │
│   │     ├── live index:    entries[name] = Entry(dt, key, value) │
│   │     ├── cache file:    files/auto_registry.cache             │
│   │     ├── dump file:     files/auto_registry.txt               │
│   │     └── onChange:      (name, value) → CarChannel.sink       │
│   │                                                              │
│   ├── watchdog: DaemonWatchdog                                   │
│   │     └── 30s ping → daemon.ping(); retry via AdbBootstrap     │
│   │                                                              │
│   ├── persistence: LkvPersistence                                │
│   │     └── label-keyed LKV, survives reboots                    │
│   │                                                              │
│   └── readStatus(tier?):                                         │
│         registry.built ? servePromInRegistry() : daemonBatch()   │
└──────────────────────────────────────────────────────────────────┘
```

## `BydAutoFeatureIdsCatalog` — the universe

The framework class `android.hardware.bydauto.BYDAutoFeatureIds` defines
all the public feature-id constants. They are `public static final int`
fields, grouped into the root class and a set of nested classes
(`Door`, `Ac`, `Bodywork`, `Light`, `Statistic`, `Instrument`, …).

`BydAutoFeatureIdsCatalog` reflects them once on first access:

- Root-class fields are stored under their bare name (`AC_POWER_STATE`).
- Nested-class fields are stored **twice** — once bare and once
  prefixed (`Ac.AC_POWER_STATE`). This is intentional:
  - Prefixed form disambiguates collisions across groups (e.g. root
    `X` vs `Setting.X`).
  - Bare form keeps any pre-migration textproto entries that used the
    unprefixed name working.
- First registration wins, so the bare-name registration (added
  before the nested walk) takes precedence for any name that exists
  in both root and a nested class.

This is why the catalog reports `~21k` names on DiLink 5.1+ — the
underlying constant count is roughly half that, doubled by the
bare-and-prefixed storage. See [`auto-discover-math.md`](./auto-discover-math.md)
for the actual probe economics.

**Failure mode** — non-BYD device, stripped framework, app installed
on emulator: `Class.forName(ROOT)` throws, `byName` is empty, every
downstream `resolve(name)` returns null. Callers degrade gracefully.

## `InAppPushManager` — the dispatcher

Builds one `BydPushDevice` instance per device-type in `WARM_DT`:

| `dt` | Subsystem |
|------|-----------|
| 1000 | AC |
| 1001 | BODY (cluster + tires + battery stats) |
| 1023 | SETTING / SENSOR |
| 1038 | GEAR |
| 1040 | WHEEL |
| 1041 | DOORLOCK |
| 1045 | TIRE |

**Why in-app and not shell-UID daemon** — verified empirically on
DiLink 5.1 (12 May 2026): the framework dispatches
`AbsBYDAutoDevice.onPostEvent` only to instances constructed with a
bound `Application` context. The shell-UID daemon uses
`ActivityThread.getSystemContext()` and never receives a frame.
`pushFramesReceived` stays at 0 even with live keys subscribed. The
split therefore is:

- `set` (writes) → must go through the shell-UID daemon
- `get` → either path works
- `push` → must be in-app

**Hot dispatch path** — one sink shared across all per-dt devices. On
each `onPostEvent`:

1. Compute the composite key `(dt << 32) | (key & 0xFFFFFFFF)`.
2. `subs[composite]?.let { dispatch each callback }`.
3. Snapshot the callback list under lock so concurrent unsubscribe
   can't NPE mid-iteration.

The composite key avoids a nested-map allocation; subscribe/unsubscribe
are amortised O(1).

## `AutoCarRegistry` — auto-discovery

The brute-force probe:

```
for dt in WARM_DT (7 device-types):
  for chunk in catalog.keys.chunked(CHUNK_SIZE=64):
    results = AdbShellBridge.fastBatchGet(chunk.map { (dt, key) })
    for (i, value) in results:
      if value not in SENTINELS:
        entries.putIfAbsent(name, Entry(name, dt, key, value))   # first-wins
```

- Catalog has ~21k entries. WARM_DT has 7. CHUNK_SIZE is 64. That's
  ~21000 × 7 / 64 ≈ 2,300 daemon `getIA` round-trips, ~2–5 seconds
  on real hardware.
- `SENTINELS` are the BYD-framework error codes meaning "feature key
  not bound / not initialised / permission denied":

  | Value | Meaning |
  |-------|---------|
  | -10011 | feature key not bound / not supported on this trim |
  | -10013 | statistics-class signal not yet computed |
  | -10006 | value not initialized yet (CAN signal hasn't fired) |
  | -10005 | permission denied for current process UID |
  | -10001 | framework still booting |
  | 65535  | uint16 -1 / no data |
  | Int.MIN_VALUE | InAppPushManager device-type not registered |

- First non-sentinel value wins; duplicates across device-types are
  ignored. This is why on Leopard 8 the registry settles at ~9k
  entries — many catalog names return sentinel under every WARM_DT
  (write-only commands, signals scoped to subsystems we don't probe,
  features the framework knows but the hardware doesn't implement).
  Full math in [`auto-discover-math.md`](./auto-discover-math.md).

### Cache fast-path

After a successful probe, `AutoCarRegistry` writes
`files/auto_registry.cache`:

```
v1|<catalog.size>|<first-name>|<last-name>          # signature line
name1\tdt1\tkey1
name2\tdt2\tkey2
…
```

The signature changes when the framework catalog adds, removes, or
reorders entries — i.e. a ROM bump. Routine app boots all see the
same signature and take the fast-path:

1. Restore `(name, dt, key)` tuples from disk.
2. `subscribeAll()` — register push callbacks for every entry.
3. `seedValuesFromDaemon()` — one bulk `getIntArray` per dt to fill
   `Entry.value` before push fires (static signals might never
   emit a frame on their own).

Total cold start: ~150 ms vs ~2–5 s for the brute-force path.

Values are **not** cached on disk — push fills them in seconds, and
a stale cached value would surface as "ancient last-known" before
the first frame.

### `onChange` callback

```kotlin
@Volatile var onChange: ((String, Int) -> Unit)? = null
```

Single-listener (the `CarChannel.registryEventChannel` sink). On every
push frame after the internal value update, `onChange(name, value)`
fires. The bridge forwards to Dart over the EventChannel. If we
ever need multi-consumer fanout we promote to `CopyOnWriteArrayList`.

## `AutoFeatureService.readStatus` — the pivot

Historically `readStatus` issued one daemon `getInt` per status key
every tick. The pivot:

```kotlin
if (registry.built) {
    // Production fast path — serve from in-memory registry.
    for (sk in plan) {
        val name = intToName[sk.key] ?: continue
        val rec = registry.get(name) ?: continue
        out[sk.label] = rec.value
        if (now - rec.lastUpdateMs > 60_000L)
            ages[sk.label] = age
    }
    return out
}
// Cold-path / fallback (registry not built yet or non-BYD ROM)
…daemon batch + in-app overlay…
```

- Zero Binder calls per `readStatus` once warm.
- Same wire shape as before — Dart-side consumers see no change.
- Tier filtering (`HOT` / `WARM` / `COLD`) survives because we still
  filter the textproto-curated `plan` upstream; the registry just
  provides the values.

## `StatusKeyCatalog` — curated label map

The hardcoded list of ~30 `(label, deviceType, featureName, valueKind)`
tuples. Migrated from `android/app/src/main/assets/offline/car_table.textproto` on
12 May 2026 so:

- There's no encrypted-asset round-trip on first read.
- A single Kotlin source of truth covers the dashboard's named keys.
- Names that don't resolve on a given trim are silently dropped at
  `build()` — same cross-trim behaviour as the old encrypted source.

`AutoFeatureService.labelToCatalog()` exposes `label → catalog name`
via the bridge for Dart consumers that need to translate.

## `DaemonWatchdog` — set-side recovery

The shell-UID daemon can die (low-memory kill, ADB severed,
unhandled exception on a stale path). When that happens:

- Push subs keep delivering — they bypass the daemon entirely.
- But `setInt` calls fail with `disconnected`.

The watchdog runs forever, pings every 30 s with a 1 s timeout, and
after 3 consecutive failures invokes `AdbBootstrap.retry` with
exponential backoff (30 s → 5 min cap). On a successful ping
following a retry, backoff resets to initial.

## `LkvPersistence` — restart-survival

Last-known-value cache keyed by `StatusKey.label`. Stored as wall-
clock-anchored snapshots (not `elapsedRealtime`) so age survives
reboot. Surfaces as `__field_age_ms` on `readStatus` whenever the
value is older than 60 s. The dashboard renders `--` when both LKV
and registry have nothing.

## File map

| File | Role |
|------|------|
| `AutoFeatureService.kt` | Composer, owns lifecycle, exposes `readStatus` + the registry surface methods. |
| `AutoCarRegistry.kt` | Auto-discovery + cache + push subscribe + onChange. |
| `BydAutoFeatureIdsCatalog.kt` | Framework name → int reflection. |
| `StatusKeyCatalog.kt` | Curated label → name set for legacy widgets. |
| `InAppPushManager.kt` | One `BydPushDevice` per `WARM_DT`; dispatch sink. |
| `helper/BydPushDevice.java` | Subclass of `AbsBYDAutoDevice`; reflects framework methods. |
| `helper/DashDaemon.java` | Shell-UID daemon (writes + bulk read). |
| `daemon/DaemonWatchdog.kt` | Ping + retry for the daemon. |
| `LkvPersistence.kt` | On-disk LKV cache. |
| `CarChannel.kt` | The bridge — covered in [`bridge.md`](./bridge.md). |
