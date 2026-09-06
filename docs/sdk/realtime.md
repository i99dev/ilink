# Real-time updates

How dashboard tiles get fresh values without an app restart, and why
the obvious approach (frameworks call us back) doesn't work for our
UID.

## TL;DR

- Daemon polls a hot subset of `(dt, key)` pairs every 200 ms via
  `BYDAutoMgr.getInt` reflection, diffs against last-known, emits
  `{event:"change", subId, value, atMs}` JSON frames over TCP to every
  subscribed client.
- App receives those frames, routes by name through the SDK's hot
  cache, notifies per-name watchers, widgets rebuild.
- End-to-end latency: ~200 ms per push frame, plus single-digit ms for
  the binder hop and channel marshalling.

## Why not `IBYDAutoListener.registerListener`

The BYD framework exposes `AbsBYDAutoDevice.registerListener(IBYDAutoListener)`
and an `onPostEvent`/`onDataChanged` callback — the obvious push channel.
We tried it three times. **It silently rejects unprivileged-UID
callers.**

Verified empirically on Leopard 8 (DiLink 5.1), 12 May 2026:

```
$ adb logcat | grep BaseRepository
[BydAc]BaseRepository: onDataChanged propertyValue = PropertyValue{mId=315 …}
[BydAc]BaseRepository: onDataChanged propertyValue = PropertyValue{mId=317 …}
…
```

These dispatches go to **PIDs 1724 / 2232 / 3451** — every one a
`system`-UID `com.byd.*` process (`acservice`, `car.server`, `gpsinfo`).
Our `u0_a239` app PID never receives a single frame. We instrumented a
process-wide `framesReceived` counter on `BydPushDevice` to confirm:
0 frames after 30 sec of car activity, every time, across multiple
register-then-wait variants.

The BYD framework's registration path checks calling UID against an
allow-list before adding the listener to its dispatch table. Listener
registration succeeds (no exception), but the listener is never
invoked.

## What dudu Launcher does

dudu Launcher's smali (`c1/com/dudu/.../api/a.smali` etc.) shows the
exact pattern we tried:

```smali
invoke-super {p0, p1},
  Landroid/hardware/bydauto/AbsBYDAutoDevice;->registerListener(
    Landroid/hardware/IBYDAutoListener;)V
```

It works for them because dudu installs as a system-signed app on
rooted BYD HUs / custom ROMs. We're a normal-UID Play-Store-style app;
no path to that signing without flashing the device.

## What we ship instead

`AutoFeatureService.subscribePushByName(name)` resolves the name's
device-type once (via the persistent cache or a 7-DT probe), then asks
the daemon to subscribe via `DashDaemonClient.subscribe(dt, key, callback)`.

Daemon side, the subscribe handler appends a `Sub` entry to its `subs`
map. A single `dashd-sub-poll` thread runs `pollSubs()` every 200 ms:

```java
for (var entry : subs.entrySet()) {
    Sub s = entry.getValue();
    int v = (Integer) getIntM.invoke(autoMgr, s.dt, s.key);
    if (v == s.lastValue) continue;
    s.lastValue = v;
    // emit {event:"change", subId, value, atMs} over TCP
}
```

Source: `android/app/src/main/java/.../helper/DashDaemon.java` (the
`pollSubs` + `startSubPoller` methods).

When a frame arrives in the app, `AutoFeatureService` calls
`sdkPushOnChange(name, value)` which CarChannel forwards on the
`ilink/car/registry` EventChannel. `BydClient` listens, updates its
`_values` cache, and fires the per-name watcher.

## The (name → dt) cache

The first time we subscribe to a name we don't already know the dt
for, we have to probe each candidate device-type via daemon `getInt`
until one returns a non-sentinel value (~5 ms × ≤7 dts = ~35 ms). To
avoid repeating that on every cold start, the resolved (name → dt)
pair is persisted to `<filesDir>/byd_name_to_dt.json` (debounced 500 ms
to coalesce burst subscribes).

Warm starts read the cache on `AutoFeatureService` construct and skip
the probe entirely.

Source: `AutoFeatureService.kt` — `nameToDt`, `dtMapFile`,
`schedulePersist`, `persistDtMap`.

## Cost and limits

- **Daemon CPU**: 22 hot subs × 200 ms = ~110 binder hops / sec on the
  daemon thread. Comfortably inside the budget.
- **Gate probe screen**: opens 176 subs at once; per-tick cost ~1 ms
  per name = right at the edge of one tick. Acceptable for a
  diagnostic surface that's not always open.
- **Per-app daemon connection**: TCP loopback, single persistent
  connection per app process. Reconnect on daemon respawn (handled by
  `AdbShellBridge` + `DaemonWatchdog`).

## Push frame counter — when it matters

`BydPushDevice.framesReceived` (visible on the gate-probe screen as
`push: N frames`) counts framework `onDataChanged` callbacks reaching
the app process. It's expected to stay **0** on app UID — that's the
documented failure mode.

If it ever flips non-zero in the field, the device has been reflashed
or repackaged with system-level access; we can short-circuit the
daemon poll for those subs and run on framework push directly.
The plumbing is left in place for that case as a tripwire — see the
`registryStats()` map in `AutoFeatureService.kt`.

## Settings vs. hot signals

For the few things ContentProviders DO publish (settings: brightness,
volume, warning toggles), `CarStatusProviderSource.observeFamily`
registers `ContentObserver`s and forwards snapshots through the
`ilink/car/observers` EventChannel. We did NOT wire this for hot
dashboard signals — `com.byd.carStatusProvider/car_status` only
contains maintenance / travel-points history; speed, gear, doors, AC
mode, SOC are NOT there. That's why daemon polling is the answer for
the dashboard.
