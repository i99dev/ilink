# 5. Launch mechanisms — which transport per screen, and why

Three screens, **three behaviours**. Picking the wrong transport for a
screen is the single biggest cause of "card reacts but nothing casts".

## Decision table (Di5.0 / `passenger == DishareQuickShare`)

| Target | Transport | Command / sequence | App must be foreground first? |
|--------|-----------|--------------------|-------------------------------|
| **IVI (0)** | local launch | `Context.startActivity` (plan `IviLocal`) | n/a |
| **FSE / passenger (2)** | **DiShare mirror** | `register(pkg)` → `setVideoSize` → `setGestureShare(true)` → `quickShare("fse")` (ops 1/11/9/8) | **YES** — launch on display 0, wait ~1200 ms, then quickShare |
| **Cluster — Small Panel (3)** | **shell am-start** | `am start -S --display 3 --activity-multiple-task --activity-clear-top -n <comp>` over shell-uid ADB | n/a (am-start *is* the launch) |
| **Cluster — Driver Dashboard (4)** | **shell am-start** | `am start -S --display 4 --activity-multiple-task --activity-clear-top -n <comp>` over shell-uid ADB | n/a |

## Why FSE is a *mirror* and cluster is a *launch*

- **FSE (2)**: DiShare's job is to **mirror the IVI window of a
  registered package** onto the passenger panel. `register(pkg)` tells
  DiShare *which* package to capture; it captures that package's
  **foreground window on display 0**. If the app isn't up on the IVI,
  there is nothing to mirror → "nothing casts" even though every
  binder call returns ok. Hence Shaheen's `launchIvi(pkg)` + 1200 ms
  *before* `fireDiShare`.
- **Cluster (3/4)**: `dishareDevice == null` in Shaheen's `Target` —
  DiShare has no mirror route for the cluster on this ROM. The app is
  **placed directly** on the cluster display via `am start --display
  N`. It must run as **shell uid** (real ADB `shell:` stream), because
  `FLAG_OWN_CONTENT_ONLY` + owner `com.byd.containerservice` causes an
  app-uid `am start --display N` to be re-homed to display 0.

## Common failure modes (observed this session)

| Symptom | Cause | Fix |
|---|---|---|
| Green check, nothing on panel | `transact()` swallowed `readException` / read a bogus reply int → false success **OR** cb binder didn't answer `INTERFACE_TRANSACTION` so DiShare rejected the client | Match Shaheen reply handling + cb binder ([03](./03-dishare-binder-protocol.md)) |
| "register failed" | wrong opcodes (`7/8/5/15`) or `reply.readInt()` reading past EOF | Use `1/8/9/11`, `readException`+`return true` |
| FSE: binder all-ok but blank panel | app not foreground on display 0 before `quickShare` | launch on 0 → wait 1200 ms → quickShare |
| Cluster: "shows on same screen" (display 0) | `am start --display N` ran as app uid, re-homed to 0 — or self-ADB bridge not connected so the shell command never ran | run via connected shell-uid ADB; verify it's connected |
| Small Panel lands on Driver | display-group re-home from empty state | verify-then-retry on the requested displayId |

## On-car PROOF (2026-05-18, host `adb shell`, shell uid)

Ran the exact `am start -S --display N --activity-multiple-task
--activity-clear-top -n com.android.chrome/…Main` per display and read
`am stack list` / `dumpsys activity activities`:

| display | result | conclusion |
|---|---|---|
| **4** (Driver) | `RootTask … displayId=4`, task **`visible=true`** | am-start **works** |
| **3** (Small Panel) | task on **`displayId=3`** | am-start **works** |
| **2** (FSE/passenger) | `RootTask … displayId=2` but task **`visible=false visibleRequested=false translucent=true isExiting`** | am-start **does NOT render** — passenger is DiShare-only |

This upgrades the FSE-vs-cluster split from *inferred* to *proven*:
**`am start --display 2` creates the task on the passenger display
but it never becomes visible** (immediately paused/exiting). The
passenger panel is reachable **only** via the DiShare mirror path
(foreground app on IVI → ~1200 ms → `quickShare("fse")`). The cluster
(3/4) is reachable **only** via shell-uid am-start. They are not
interchangeable. car-ilink's planner already encodes this
(cluster→`ShellLaunch`, FSE→`Dishare`).

## Cluster touchpad — interaction transport (after the app is placed)

Launching the app on the cluster is only half the story; the driver
then drives it from the IVI trackpad via the **cluster touchpad**.
This is a *separate* transport from the launch path above, and its
cursor and input target **different displays** on Di5.0:

| Op | Target display | Native call | Notes |
|----|----------------|-------------|-------|
| Cursor overlay (the dot) | **4** (Driver Dashboard) | `ClusterCursorOverlay.show/move` on a `createDisplayContext(4)` `TYPE_APPLICATION_OVERLAY` | Renders on the visible layer. `cursorRemap` is identity on Di5.0. |
| Tap / swipe | **2** (DiShare source) | `input -d 2 tap\|swipe …` over the shell-uid ADB bridge | Display 4 has no touchable window; `inputRemap = {4→2}` routes here. |

Verified on the live L5 (2026-05-20):

- `input -d 2 tap 960 360` → delivered to the cast app
  (`InputDispatcher: debug_input … displayId:2 … <pkg>`).
- `input -d 4 tap 960 360` → **dropped** (`no touchable window …
  in display 4`).

Why they differ: displays 3 and 4 are independent **siblings** (both
`mDisplayIdToMirror=0` — mirror display 0, not each other), so the
cursor must live on 4 to be seen, while the cast app's focusable
window lands on the DiShare source display (2). The full reasoning +
the `dumpsys` evidence is in
[01 — Cluster touchpad routing](./01-display-topology.md#cluster-touchpad-routing-cursor-vs-tap-land-on-different-displays).

> **Do not** reuse Di5.1/L8's cursor/input remap (`{3→5,5→5}` /
> `{5→3}`) on Di5.0 — that topology has a true parent/child mirror;
> L5 does not.

## What is NOT the mechanism (ruled out)

- **2-finger swipe / `MultiTouchInjector`** — a pre-`#121` car-ilink
  path. Shaheen's `RouteEngine` does **no** gesture injection for FSE
  or cluster. Removed; do not reintroduce for Di5.0.
- **DiShare quickShare to `cluster_c`/`cluster_tr`** — binder returns
  ok but never paints the cluster on this ROM; cluster is am-start.
- **Special permission grant** — Shaheen's only `appops` is
  `SYSTEM_ALERT_WINDOW` for its own overlay; there is no magic
  cluster-unlock permission. The privilege is just *shell uid*.
- **Detection / profile / planner routing** — all verified correct;
  not a contributor.
