# 1. DiLink 5.0 — Display topology

Captured from the live L5 (`127.0.0.1:5999`, ROM `23.1.4.2510219.1`)
via `dumpsys display` / `dumpsys SurfaceFlinger` / `am stack list`.

## The four displays

| id | name | type | size | owner | flags | role (car-ilink) | user label |
|----|------|------|------|-------|-------|--------------------|------------|
| **0** | `Built-in Screen` | INTERNAL, default | 2560×1440 | system | `FLAG_SECURE`, `FLAG_TRUSTED`, default | IVI / head unit | Head Unit |
| **2** | `fission_bg_XDJAScreenProjection` | VIRTUAL | 1920×720 | `com.byd.containerservice` (uid 1000) | `FLAG_PRESENTATION`, `FLAG_OWN_CONTENT_ONLY` | passenger | FSE Co-pilot |
| **3** | `shared_fission_bg_XDJAScreenProjection_0` | VIRTUAL | 1920×720 | `com.byd.containerservice` (uid 1000) | `FLAG_PRESENTATION`, `FLAG_OWN_CONTENT_ONLY` | passenger\* (hidden) | Small Panel |
| **4** | `shared_fission_bg_XDJAScreenProjection_1` | VIRTUAL | 1920×720 | `com.byd.containerservice` (uid 1000) | `FLAG_PRESENTATION`, `FLAG_OWN_CONTENT_ONLY` | **cluster**† | Driver Dashboard |

\* The owner-package classifier layer maps **every** BYD-container slot
to `passenger` (`LEOPARD5_PROFILE.secondaryDisplayOwners =
{"com.byd.containerservice": "passenger"}`) — displays 2 and 3 stay
`passenger` on that rule.

† **Display 4 is pinned to `cluster`** by
`DisplayProfile.clusterDisplayId = 4` (set on the `DI50_BYD_DISHARE`
archetype). The owner-package layer can't distinguish the Driver
Dashboard from the passenger slots — they share one owner — so the
classifier checks `clusterDisplayId` **before** the owner-package
layer (`DisplayClassifier` Layer 0) and emits `role=cluster` for id 4
only. This is what lets the picker badge it as the driver target and
the cluster touchpad attach to it (see *Cluster touchpad routing*
below). The instrument cluster's real MCU is **not** an Android
display on Di5.0 — the OS only enumerates 0/2/3/4. Displays 3/4 are
*paintable projection virtuals*, **not** the daemon-locked cluster
MCU. User-facing labels come from
`overrideLabels = {2:"FSE Co-pilot", 3:"Small Panel",
4:"Driver Dashboard"}`.

> Name says `XDJAScreenProjection` but the **owner is
> `com.byd.containerservice`**, NOT XDJA. `com.xdja.containerservice`
> is absent on Di5.0. Never classify by the display *name* substring.

## The hard constraint: `FLAG_OWN_CONTENT_ONLY`

Displays 2/3/4 are `VIRTUAL` + `FLAG_PRESENTATION` +
**`FLAG_OWN_CONTENT_ONLY`**, owned by `com.byd.containerservice`
(uid 1000). Consequences:

- They do **not** mirror display 0 automatically — they show only
  content explicitly targeted at them.
- A normal in-app `am start --display N` (app uid) is **silently
  re-homed to display 0**. This is the root reason naïve
  display-targeting "does nothing / shows on the same screen".
- The empirically-observed steady state: **every task is on
  `displayId=0`**. `am stack list` on the live L5 shows ilink,
  launcher, byd.mycar, telegram, i99doctor — *all* on display 0;
  nothing ever on 2/3/4.

### Don't confuse split-screen with cluster

`am stack list` shows `RootTask id=3 bounds=[0,0][1270,1440]
displayId=0` and `RootTask id=4 bounds=[1290,0][2560,1440]
displayId=0`. These are the **left/right split-screen halves of the
2560-wide display 0**, *not* displays 3/4. Always key off
`displayId=`, never the RootTask id.

## What the two screen classes actually need

| Screen | Reaches it via | Why |
|--------|----------------|-----|
| **FSE / passenger (2)** | DiShare *mirror* (`quickShare("fse")`) **after the app is foreground on display 0** | DiShare captures the IVI window of the registered package and mirrors it to the passenger panel |
| **Cluster (3 / 4)** | `am start -S --display N …` over a **shell-uid** ADB stream | shell uid (2000) is privileged enough to place an activity directly onto the owner-locked virtual display, where an app-uid start is dropped |

`SurfaceFlinger` layer-stacks confirm 2/3/4 are independent
(`mCurrentLayerStack=2/3/4` respectively, distinct from display 0's
`layerStack 0`) — they are *separate* surfaces, not mirrors of each
other. So both panels can show different content; the difficulty is
purely *placing* content there from a non-owner.

## Display-group quirk (Small Panel flakiness)

Displays 3 & 4 behave as one BYD-container display **group**. From an
empty group state, `am start --display 3` is frequently re-homed by
ActivityManager onto the group's active display (**4 = Driver**). Once
a task exists on 4, a subsequent `--display 3` is honored. This is
exactly the field symptom: *"Small Panel sometimes opens on Driver;
but if something is already on Driver then Small Panel works."* The
mitigation is **verify-then-retry** (launch, confirm via
`am stack list` which display it landed on, re-issue) — see
[06](./06-car-ilink-implementation.md).

## Cluster touchpad routing (cursor vs. tap land on different displays)

Once an app is on the cluster (Driver Dashboard, display 4), the
**cluster touchpad** lets the driver drive it from the IVI trackpad.
The cursor and the tap target **different displays** on Di5.0 — this
is the key gotcha, verified on the live L5 (2026-05-20):

| What | Display | Why |
|------|---------|-----|
| **Cursor overlay** | **4** (identity) | The `TYPE_APPLICATION_OVERLAY` dot must render on the layer the driver actually sees. Displays 3 and 4 are **siblings** (`dumpsys display` shows `mDisplayIdToMirror=0` on **both** — each mirrors display 0, **not** each other), so a cursor painted on 3 is invisible to a driver looking at 4. The overlay's z-stacking puts it above the cast frames on layer 4 itself. |
| **Tap / swipe** | **2** | Display 4 carries **no touchable window** — `input -d 4 tap` is dropped with `InputDispatcher: Dropping event because there is no touchable window … in display 4`. The cast app's focusable Activity + input window live on the DiShare **source** display (2); `input -d 2 tap X Y` lands on the cast cleanly. |

Encoded in the profile as:

```kotlin
// DI50_BYD_DISHARE (Archetypes.kt)
cursorRemap = emptyMap(),       // identity → cursor stays on 4
inputRemap  = mapOf(4 to 2),    // tap on 4 routes to 2
```

> **Do NOT** copy Di5.1/L8's `cursorRemap = {3→5, 5→5}` /
> `inputRemap = {5→3}` onto Di5.0. That topology has a real
> parent/child mirror (display 3 mirrors the eyeline cluster 5); L5
> does not — 3 and 4 are independent siblings of 0. The
> pre-2026-05-20 theory routed the L5 cursor to display 3 by analogy
> and the dot was invisible; the dumpsys `mDisplayIdToMirror` check
> is the disambiguator.

The DiShare/shell launch path that *places* the app on the cluster is
unchanged and independent of this — see
[05](./05-launch-mechanisms.md).
