# 4. Shaheen reference architecture (the spec to match)

`Shaheen.apk` = `com.the4.navigator`, the user's **working** app on
this exact car. Decompiled 2026-05-18 (8 dex; the relevant classes are
**un-obfuscated**). This is the authoritative behavioural spec for
Di5.0 multi-screen launch.

Key classes:
- `com.the4.navigator.Targets` / `Targets$Target`
- `com.the4.navigator.RouteEngine`
- `com.the4.navigator.DiShareCore` (+ `$1` cb binder, `$ParcelWriter`)
- `com.the4.navigator.adb.AdbConnectionManager` (+ `AdbClient`,
  `AdbKeyStore`, `executeRaw`, `submit`, `connectionLoop`,
  `bootstrapPermissions`)

## `Targets$Target`

`Target(key:String, label:String, displayId:Int, dishareDevice:String?,
lockedByDefault:Boolean)`

| static | key | label | displayId | dishareDevice |
|--------|-----|-------|-----------|---------------|
| `IVI` | `ivi` | Main Screen | **0** | `ivi` |
| `FSE` | `fse` | FSE Co-pilot | (fse) | `fse` |
| `CLUSTER_CENTER` | `cluster_c` | Small Panel | **3** | `null` |
| `CLUSTER_TOPRIGHT` | `cluster_tr` | Driver Dashboard | **4** | `null` |

Confirms our `DISPLAY_ID_CLUSTER_CENTER=3 / TOPRIGHT=4` mapping.
**Cluster targets have `dishareDevice=null`** → they *cannot* use the
DiShare path; they are am-start-only.

## `RouteEngine` — the router

```
RouteEngine.<init>(ctx):
    DiShareCore.get(ctx).bind()                 // bind DiShare API svc
    AdbConnectionManager.get(ctx).start()       // start self-ADB bridge

route(target, pkg):
    if target.key == "ivi"  → launchIvi(pkg)
    if target.key == "fse"  → launchIvi(pkg)                  // 1. app onto IVI
                              mainHandler.postDelayed(         // 2. wait 1200 ms
                                  { fireDiShare(pkg, target) }, 1200)   // 3. DiShare mirror
    else /* cluster_c|cluster_tr */ → launchCluster(target, pkg)
```

### `fireDiShare(pkg, target)` — FSE / passenger (DiShare mirror)

```
if (!DiShareCore.isConnected()) Toast "DiShare not bound …"; return
DiShareCore.register(pkg)            // op 1
DiShareCore.setVideoSize(w, h)       // op 11
DiShareCore.setGestureShare(true)    // op 9
DiShareCore.quickShare(target.dishareDevice)   // op 8, e.g. "fse"
Toast "Shared … register=.. setVideoSize=.. setGestureShare=.. quickShare=.."
```

Pure binder. **No swipe / gesture injection.** Crucially it is only
reached **after `launchIvi(pkg)` + a 1200 ms delay** — DiShare mirrors
the *foreground* window of the registered package, so the app must be
up on display 0 first.

### `launchCluster(target, pkg)` — cluster (am-start over shell ADB)

```
intent = pm.getLaunchIntentForPackage(pkg)         // null → Toast, false
component = intent.getComponent()                   // null → false
if (AdbConnectionManager.state != Connected)
    Toast "<label>: ADB self-bridge connecting…"; (kick connect)
AdbConnectionManager.submit(
   "am start -S --display " + target.displayId +
   " --activity-multiple-task --activity-clear-top -n " +
   component.flattenToShortString())
```

i.e. **start the app directly on the cluster display via the embedded
ADB self-bridge.** No DiShare for cluster.

## `AdbConnectionManager` — the self-ADB bridge

Fields: `client:AdbClient`, `keyStore:AdbKeyStore`,
`_state/state:StateFlow<ConnectionState>`, `connectionJob`,
`actionChannel/queryChannel`, `connectionLoop`. Methods: `start`,
`submit`, `executeRaw`, `bootstrapPermissions`.

- Opens a real ADB **`shell:`** stream (string literal `"shell:"`) to
  the local adbd (reads `service.adb.tcp.port`; RSA key via
  `AdbKeyStore`) → commands run as **shell uid (2000)**.
- `connectionLoop` = persistent auto-reconnect; `state` is a
  `StateFlow` callers gate on (`ConnectionState.Connected`).
- `bootstrapPermissions` runs `appops set com.the4.navigator
  SYSTEM_ALERT_WINDOW allow` over the bridge — that's for Shaheen's
  **floating-launcher overlay**, *not* a cluster-display gate. There
  is **no special permission grant** that unlocks the cluster; the
  privilege is simply that the `am start` runs as shell uid.

> Net: Shaheen reaches the owner-locked cluster purely because the
> `am start --display N` runs as **shell uid** over a robust,
> always-connected self-ADB stream. The mechanism is not exotic — but
> the *robust persistent connection* is the part car-ilink must
> match (see [07](./07-open-issues-and-diagnostics.md)).

## One-paragraph spec

> To move app *P* to a screen *T* on Di5.0: if *T* is **IVI**, plain
> launch on display 0. If *T* is **FSE**, launch *P* on display 0,
> wait ~1200 ms, then DiShare `register(P)→setVideoSize→
> setGestureShare(true)→quickShare("fse")` with a correct
> `IDiShareApiClient` callback binder. If *T* is **cluster
> (3/4)**, run `am start -S --display <T.displayId>
> --activity-multiple-task --activity-clear-top -n <P/activity>` over
> a connected **shell-uid** ADB stream.
