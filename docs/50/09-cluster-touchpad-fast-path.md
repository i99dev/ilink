# Cluster touchpad — FAST-path input injection

Status: **shipped to branch, on-car verification pending** (2026-06-25). Ground
truth: dex-verified against a reverse-engineered **reference dashboard app**
(a working third-party BYD dashboard) + a full read of our own daemon stack.

## 1. What the reference app does (dex-verified)

The reference app evolved past the AccessibilityService approach we copied in
`RemoteControlAccessibilityService`. Its control core is a **persistent
shell-uid daemon**:

- Launched via `app_process64` (`nohup app_process64 -Xnoimage-dex2oat
  -Djava.class.path=… /system/bin --nice-name=… <DaemonMain>`), death-monitored,
  auto-restarting.
- **Transport: Binder/AIDL** (its daemon registers an `IBinder` via
  `ServiceManager.addService`; the app polls `getService` + `linkToDeath`).
- **"FAST path" input injection:** reflected **`InputManager.injectInputEvent()`**
  + hidden **`MotionEvent.setDisplayId()`** (and `KeyEvent.setDisplayId()`),
  building full multi-pointer `MotionEvent.obtain(...)` streams. No process fork
  per event; per-display.
- **`createVirtualDisplay` + `Presentation` + a touch-proxy service** for
  projecting/proxying a surface onto the cluster.
- a11y `GestureDescription.Builder.setDisplayId()` dispatchGesture only as a
  *fallback*.

## 2. What we have (and why this is a small change, not a new subsystem)

We already ship an equivalent daemon — as **TCP+JSON instead of Binder+AIDL**,
and it's already proven on-car (nav-HUD, cluster patcher):

| reference app | ilink (existing) |
| --- | --- |
| `app_process64 … <DaemonMain>` | `app_process64 … com.i99dev.ilink.helper.DashDaemon` (`AdbShellBridge.ensureDaemon`) |
| Binder `IBinder` service | TCP 127.0.0.1:58733, line-delimited JSON (`DashDaemonClient`) |
| death-monitored, auto-restart | `DaemonWatchdog` (ping/backoff/respawn), port-as-mutex, self-heal |
| `injectInputEvent`+`setDisplayId` | **MISSING — this is the only new capability** |
| token-gated privileged surface | `exec` op, `DASHD_EXEC_TOKEN`, capability advertisement |

We also already have the **centralized gesture seam** the touchpad should use but
doesn't: `ilink/gesture` (`InputPlatformPlugin` → `RemoteControlAccessibilityService`
dispatchGesture, ADB fallback) + `DisplayInputResolver` (the 5→3 input remap).
Today only mini-apps (`GestureFamily`) use it; the cluster touchpad still uses the
legacy `ilink/pkg` → `clusterInput.*` → `input -d N tap/swipe` shell-fork path.

## 3. Target architecture (centralized, one seam, tiered)

```
cluster_touchpad (relative trackpad UI)        mini-apps (gesture family)
                 \                                   /
                  ──────────► ilink/gesture ◄──────
                              (InputPlatformPlugin)
                                     │  tier order, feature-detected:
                                     ├─ 0 DashDaemon inject  ........ FAST  (new)
                                     │     injectInputEvent + setDisplayId
                                     │     streaming ptr down/move/up (sendOneWay)
                                     ├─ 1 a11y dispatchGesture ....... discrete fallback
                                     └─ 2 ADB `input -d N` ........... last resort
                              DisplayInputResolver (5→3) applied once, here
```

- **Delete** the duplicate input path: `pkg/ClusterInput.kt` and the
  `clusterInput.tap/swipe/key/text` methods on `ClusterChannels` /
  `PkgNativeBridge` / `PlatformPkgNativeBridge`. (Cursor overlay + `clusterClear`
  stay — different concern.)
- **One** display-remap authority (`DisplayInputResolver`), not the touchpad's
  hand-rolled `inputDisplayId`/`cursorDisplayId` *and* the resolver. The
  profile-derived `ClusterTouchpadTarget` keeps width/height/label/cursor-display;
  it passes the input display id through the gesture seam, where the resolver is
  idempotent.

## 4. Daemon wire additions (`DashDaemon`)

New helper `InputInjector` (mirrors the `AutoManagerActuator` extraction — daemon
keeps only wire+lifecycle). New ops in `handle()`:

| op | body | reply | notes |
| --- | --- | --- | --- |
| `injTap` | `displayId,x,y` | `{ok}` | one DOWN+UP at (x,y) |
| `injPtr` | `phase:down\|move\|up\|cancel, displayId,x,y` | `{ok}` (move via `sendOneWay`, no reply awaited) | per-display pointer session; consistent `downTime`; **auto-lift** watchdog so a dropped `up` can't wedge a stuck pointer |
| `injKey` | `displayId,keycode` | `{ok}` | `KeyEvent` + best-effort `setDisplayId` |
| `caps` | — | adds `"inject":true` | feature-detect; older daemon ⇒ flag absent ⇒ plugin falls to a11y |

Injection internals (dex-verified against the reference app): `InputManager
.getInstance()` singleton, `injectInputEvent(ev, 0)` (mode ASYNC),
`MotionEvent.setDisplayId`, `MotionEvent.obtain(...)` with
`source = InputDevice.SOURCE_TOUCHSCREEN`, hidden-API unlock via
`VMRuntime.setHiddenApiExemptions`.

## 5. Relative-trackpad UX (Dart)

`ClusterTouchpadForwarder` retargets to `GestureNativeBridge`. New controller:

- Maintain `cursor` in cluster px. Finger delta → `cursor += delta * gain(accel)`,
  clamp to `[0,W]×[0,H]`. Cursor overlay (`clusterCursor*`) becomes load-bearing
  (no absolute mapping to fall back on) and tracks the cursor.
- **down** → start ptr session at cursor; **move** → stream `ptrMove` (throttled to
  display refresh, fire-and-forget); **lift with < slop travel** → `tap` at cursor;
  two-finger drag → stream a press at the cursor; two-finger tap → BACK.

## 5b. Projecting ilink's OWN UI onto the cluster (VirtualDisplay + Presentation)

The reference app's *other* cluster mechanism is a VirtualDisplay + `Presentation`
+ a touch-proxy service — used to show its own dashboard on the cluster. We adopt
the idea, not the implementation:

- **NOT a port of its daemon `createVirtualDisplay(Surface)`.** That daemon
  receives the app's `Surface` over **Binder**; ours is **TCP+JSON**, and a
  `Surface` (a kernel object reference) cannot cross a socket. We don't need it:
  `ClusterActivity` already creates the VirtualDisplay **app-side** for the
  foreign-app cast (the L7-safe own-VD group, never BYD's group-0).
- The only gap was that `ClusterActivity`'s VD hosted *foreign apps* only. Now
  `EXTRA_PROJECT_BUNDLE` mode hosts **our own** sandboxed WebView (a mini-app
  bundle) on a `Presentation` over that VD — `SecondarySurfaceWebView` so the
  surface carries the identical sandbox posture as every other secondary
  surface. Entry: `PkgNativeBridge.projectContentToCluster(bundleUri, displayId)`
  → `projectContentCluster` → am-start `ClusterActivity`.
- This is a **passive display surface**: it forwards **no** synthetic touch. Our
  own UI needs no injected input (unlike a foreign-app cast). So the touchpad/
  injection seam and the content projection are orthogonal — the input work
  (§1–§4) controls *foreign* apps on the cluster; this shows *our* UI there.

## 6. Fallback & safety

- No daemon / `inject` cap absent → plugin uses a11y dispatchGesture; relative
  streaming degrades to coalesced discrete swipes (today's behavior preserved).
  A stale pre-inject daemon is auto-respawned once (`AdbShellBridge.injectReady`).
- The daemon's `inject` ops are ungated, consistent with the existing `set`/`get`
  CAN ops on the same loopback port (which are more sensitive); only `exec`
  (arbitrary shell) carries the token.
- Auto-lift + session-on-display guards prevent a stuck synthetic pointer.
