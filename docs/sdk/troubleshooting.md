# Troubleshooting

What to check when the dashboard isn't showing what it should.

## Diagnostic surface

```
Settings → Diagnostics → Gate probe
```

The gate-probe screen shows every catalog name the SDK knows about,
green dot = live value available, grey = never received. The header
strip shows three numbers:

```
151 / 176 fields live · push: 0 frames · 151 subs
```

| Field             | Meaning                                                         |
|-------------------|-----------------------------------------------------------------|
| `N / 176 fields live` | Names with a non-null cached value. Should climb to ~150 within 30 s of open. |
| `push: N frames`  | Framework `IBYDAutoListener` callbacks. **Expected to stay 0** on app UID — see [`realtime.md`](./realtime.md). |
| `M subs`          | Active daemon-poll subscriptions. Should match green-dot count once warmup finishes. |

## Empty dashboard right after install

**Symptom**: every tile shows `--` or `?` after `install -r` /
`am force-stop` + relaunch.

**Likely cause**: daemon isn't running. Either the eager
`AdbShellBridge.ensureDaemon()` call in `MainActivity.onCreate` failed,
or the daemon's TCP socket was held by a zombie process.

**Check**:
```sh
adb -s <device> shell ps -A | grep app_process64
# Expect one shell-UID line. Empty = no daemon.

adb -s <device> shell logcat -d | grep -E "AdbBootstrap|ensureDaemon|dashd"
# Look for "eager ensureDaemon: true" near app start.
```

**Fix**: `pm clear` is the last resort and should not be needed in
normal operation — eager spawn was added to prevent exactly this. If
it triggers anyway, file a bug with the logcat snippet above.

## Some values stay grey forever

**Symptom**: gate probe shows a name as grey even after 30 s; widget
that uses it never paints a value.

**Likely cause**: the catalog name doesn't resolve to a live
device-type on this trim. Common reasons: hardware not fitted (e.g.
`Bodywork.BODYWORK_SUNROOF_STATE` on a no-sunroof trim), framework
returns sentinel `-10011` (UNAVAILABLE) on every WARM_DT.

**Check**: open the BYD Test app on the car — does it show the value
there? If the framework itself doesn't expose it, we can't either.

**Fix**: pick a different catalog name OR document the trim limitation
in the widget.

## Values hydrate but don't update mid-session

**Symptom**: tiles show real values on first paint, then never change
even when the underlying state changes (door opens, gear shifts, etc.).

**Likely cause**: the daemon-poll subscribe path failed for those
names (e.g. dt resolution returned null), OR the EventChannel
connection on the Dart side dropped.

**Check the host stats**:
```dart
final stats = await ref.read(carBridgeProvider).registryStats();
// stats['sdkPushSubscribedNames']  → should equal the live count
// stats['frameworkPushFramesReceived'] → expected 0
```

**Check the Dart watchers**: from the gate probe screen, observe a value
that should change (ask someone to physically open a door). If the
host stats look healthy but the screen doesn't update, the
`ilink/car/registry` event channel was canceled. Possibly a
`ref.onDispose` somewhere closed the BydClient prematurely. Filed?
Open an issue with the screen open — diagnostic screenshot lives in
the report.

## "push: 0 frames" — is that broken?

**No.** `push: 0` is the documented state on app UID. The framework's
`IBYDAutoListener` dispatch is restricted to system-signed BYD
processes (PIDs `com.byd.acservice`, `com.byd.car.server`,
`com.byd.gpsinfo`); our app cannot register a listener that the
framework will actually call.

The counter exists as a **tripwire** — if it ever flips non-zero, the
device has gained system-level signing (rooted HU, custom ROM, etc.)
and we can short-circuit the daemon poll. See [`realtime.md`](./realtime.md).

## Daemon log inspection

Our app's `Log.i` / `Log.w` calls are stripped by R8 in release
builds. To see daemon-side logs:

```sh
adb -s <device> shell cat /data/local/tmp/dashd.log | tail -50
```

The daemon logs every reflection lookup at start, every subscribe /
unsubscribe, and any `getInt` reflection failures. If you need
app-side logs for debugging, run a debug build (`./scripts/run-dev.sh`);
release-build R8 stripping is intentional.

## "I see 22 / 176 live and it never grows"

**Symptom**: gate probe header stays at the boot warm set count, the
remaining 150+ names never resolve.

**Likely cause**: daemon got disconnected after the warm-set fetch.
The `resolveLiveDt` probe needs daemon to be live; if it isn't,
returns null silently, those names never subscribe.

**Check**:
```sh
adb -s <device> shell ps -A | grep app_process64
# If empty, daemon died. Restart the app (eager ensureDaemon should
# bring it back); if not, it's the bug above.
```

## Capture a fresh per-trim dump

When a new car arrives or a ROM update lands:

```sh
# 1) On the car: Settings → Diagnostics → Auto registry → tap SD-card icon.
#    The app writes /sdcard/ilink_features.tsv.
# 2) On the host:
TARGET=192.168.4.72:5555 ./docs/features/_car_domain/feature-ids/dump.sh leopard8_dilink5.1
# Produces docs/features/_car_domain/feature-ids/leopard8_dilink5.1.tsv + .meta.json
```

Commit both files. See [`../features/_car_domain/feature-ids/README.md`](../features/_car_domain/feature-ids/README.md)
for the full removal-of-AutoCarRegistry roadmap.

## When to reach for `pm clear`

Almost never. Cases where it IS warranted:

- App state corrupted (rare; usually after an interrupted update).
- LKV file corrupted (rare; would manifest as wrong-typed entries).
- Wiping the persistent (name → dt) cache to force re-probe (debugging
  the resolveLiveDt path itself).

Note that `pm clear` wipes the (name → dt) cache and the LKV — first
launch after will pay the full 7-DT-probe cost on every name (~1-2 s
extra latency on the first gate-probe open).

Not warranted: install -r, am force-stop, normal app updates. The
eager daemon spawn handles all of those.
