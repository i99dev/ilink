# 06 · Operations — diagnostics, cache, recovery

What to do when something looks wrong, and what to expect during
normal operation.

## On-device diagnostics

### Registry dump

After every successful build, `AutoCarRegistry` writes a snapshot to
the app's private files dir:

```
files/auto_registry.txt
```

Contents:

```
AutoCarRegistry — 9579 entries (built in 3214ms)
# name	dt	key	value
Ac.AC_CYCLE_MODE	1000	1610612737	0
Ac.AC_POWER_STATE	1000	1610612738	1
Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR	1001	1610613001	0
…
```

Pulling it:

```
adb shell run-as com.i99dev.ilink cat files/auto_registry.txt
# or via the daemon (shell UID can read app filesDir):
adb shell "su shell cat /data/data/com.i99dev.ilink/files/auto_registry.txt"
```

### Cache file

```
files/auto_registry.cache
```

```
v1|21043|Ac.AC_BLOW_MODE|Wheel.WHEEL_TIRE_TEMP_RR
Ac.AC_CYCLE_MODE	1000	1610612737
Ac.AC_POWER_STATE	1000	1610612738
…
```

Line 0 is the signature `v1|<catalog.size>|<first-name>|<last-name>`.
A mismatch on next boot invalidates the cache and forces a fresh
probe. Subsequent boots restore in ~150 ms instead of probing for
~2–5 s.

To force a fresh probe (rare — after a confirmed framework regression
where the cached `(name, dt)` map no longer matches what the framework
binds):

```kotlin
auto.registry.invalidateCache()
```

Or from shell:

```
adb shell run-as com.i99dev.ilink rm files/auto_registry.cache
```

### Stats surfaces

```kotlin
auto.registryStats()
//   built: true
//   totalEntries: 9579
//   pushFramesReceived: 142315

auto.watchdogStats()
//   pingsTotal: 1234
//   pingsOk: 1231
//   consecutiveFailures: 0
//   retriesAttempted: 2
//   retriesSucceeded: 2
//   currentBackoffMs: 30000
//   lastRetryAtMs: 1747000000000

inAppPush.stats()
//   available: true
//   devicesRegistered: {1000=true, 1001=true, 1023=true, ...}
//   framesReceived: 142315
//   subKeysActive: 9579
```

`framesReceived` being zero on `available=true` is the smoking gun
that we registered but the framework isn't dispatching. Almost
always means we constructed `BydPushDevice` with a non-Application
context — see the `InAppPushManager` doc comment for the
architectural rule.

## Common operational patterns

### "Registry is empty after boot"

Check, in order:

1. `inAppPush.stats().available` — false means
   `BydPushDevice` failed to construct. Look for
   `BydPushDevice(dt=…) failed: …` in `logcat | grep InAppPush`.
2. `auto.registryStats().built` — false means
   `AutoCarRegistry.build()` aborted. Common reasons:
   - Framework catalog empty (non-BYD device).
   - Daemon never reached READY within 30 s (push works for live
     values but cold probe needs daemon `getIntArray`).
3. Logcat: `grep AutoCarRegistry` shows the build trace and any
   failure reason.

### "Values are stuck — no updates"

Push frames not arriving. Check:

1. `auto.registryStats().pushFramesReceived` — if increasing, push
   is fine; the issue is downstream.
2. `inAppPush.stats().framesReceived` — same signal at the lower
   level.
3. Are you observing on the right key? Catalog names are
   case-sensitive and include the namespace prefix
   (`Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`, not just
   `DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`).

If `pushFramesReceived` is zero across minutes, the framework
isn't dispatching to our process. See `InAppPushManager`
construction in `AutoFeatureService.init()` — must run with
`getApplicationContext()`.

### "Writes (setInt) silently fail"

Set goes through the shell-UID daemon. Check:

1. `auto.watchdogStats().consecutiveFailures` — non-zero means the
   daemon is silent.
2. `daemonStatus()` from the bridge — `{adb: true, daemon: true}` is
   healthy.
3. Logcat: `grep DaemonWatchdog` shows ping/retry history.

The watchdog auto-recovers via `AdbBootstrap.retry` after 3
consecutive failed pings, with exponential backoff (30 s → 5 min).

## Watchdog state machine

```
              ┌───────────────────┐
              │                   │
              ▼                   │
        ┌─────────┐  ping ok      │
   ┌──▶ │ HEALTHY │ ◀─────────────┘
   │    └────┬────┘
   │         │  ping fail × 3
   │         ▼
   │    ┌─────────────────┐
   │    │ RETRYING        │  AdbBootstrap.retry()
   │    │  (backoff 30s)  │  → wait `currentBackoffMs`
   │    └────┬────────────┘  → double backoff on next attempt
   │         │                  (cap 5 min)
   │         │  ping ok after retry
   └─────────┘  → reset backoff, log
                  "daemon recovered after N failed pings"
```

Single thread (`daemon-watchdog`), one Binder ping per 30 s, invisible
CPU cost.

## Cache invalidation policy

The signature changes when:

- A new DiLink ROM ships with added/removed/renamed feature constants.
- An app reinstall wipes `files/` entirely.
- An app data-clear wipes `files/` entirely.

Never invalidate the cache for:

- A new code path that happens to need a feature — the registry
  already has it; just watch it.
- A "let's force a re-probe to be safe" instinct — the cache is
  signature-keyed; it can't be stale relative to the current ROM.
  A re-probe would discover the same set, slower.

## Log signal cheatsheet

| Tag | Surfaces |
|-----|----------|
| `InAppPush` | Per-dt device construction outcomes; push frame count. |
| `AutoCarRegistry` | Build progress, cache hits/misses, dump file path. |
| `AutoFeatureService` | LKV hydration, push backfill counts, per-key failure logs. |
| `DaemonWatchdog` | Ping fail/recover transitions, retry attempts. |
| `BydFidCatalog` | Reflection result count. Logged once at first access. |
| `CarChannel` | Method-channel errors. |

A healthy boot leaves a trace like:

```
I BydFidCatalog: loaded 21043 feature IDs from android.hardware.bydauto.BYDAutoFeatureIds
W InAppPush: init done: available=true (7/7 devices) status={1000=true, ...}
W AutoCarRegistry: build entry: push.stats={available=true, ...}
W AutoCarRegistry: AutoCarRegistry restored from cache: 9579 entries in 142ms
W DaemonWatchdog: watchdog started (interval=30000ms)
```

If you see those four lines in that order, the engine is up and
healthy.
