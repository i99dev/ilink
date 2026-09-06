# 6. car-ilink implementation (state 2026-05-18)

Where the Di5.0 multi-screen logic lives, what was changed this
session, and the exact current state. **All changes uncommitted in the
working tree.**

## Files & responsibilities

| File | Role |
|---|---|
| `car/profiles/definitions/Leopard5.kt` | `LEOPARD5_PROFILE` — `passenger=DishareQuickShare`, `cluster={DishareQuickShare,Icons}`, labels/owners |
| `display/DisplayLaunchPlanner.kt` | THE decision: `plan(target, contentKind, profile, roleResolver, expectCluster) → LaunchPlan` |
| `pkg/DeviceTagResolver.kt` | Di5.0 numeric/role → DiShare device tag (`2=fse · 3=cluster_c · 4=cluster_tr`) |
| `pkg/DishareTransport.kt` | DiShare binder client (`bindApi/register/setVideoSize/setGestureShare/quickShare`, `clientBinder`, `transact`) |
| `pkg/PackagePlatformPlugin.kt` | `handleLaunch` switches on the plan; `dispatchFastCast` (FSE), `dispatchShellLaunch` (cluster) |
| `adb/AdbShellBridge.kt` | embedded self-ADB (`AdbConnection`→127.0.0.1:5555); `shell(cmd)` runs over `shell:` = shell uid |

## `LaunchPlan` set (after this session)

```
IviLocal | Dishare(deviceTag) | AmStart(displayId)
        | ShellLaunch(displayId)   ← NEW (Di5.0 cluster)
        | SurfaceCreate(displayId) | Unreachable(reason)
```

`DisplayLaunchPlanner` Di5.0 branch (`passenger==DishareQuickShare`):

```
tag = DeviceTagResolver.tagFor(...)
when (tag):
  null              → Unreachable("no DiShare path …")
  DEVICE_CLUSTER_TOPRIGHT → ShellLaunch(DISPLAY_ID_CLUSTER_TOPRIGHT /*4*/)
  DEVICE_CLUSTER_CENTER   → ShellLaunch(DISPLAY_ID_CLUSTER_CENTER  /*3*/)
  else  (fse/ivi)   → Dishare(tag)
```

## Executors in `PackagePlatformPlugin`

- **`Dishare` →** `dispatchFastCast(pkg, tag)` on `adbExecutor`:
  1. `startActivity(getLaunchIntentForPackage(pkg) | NEW_TASK)` —
     foreground on IVI (Shaheen FSE step 1)
  2. `Thread.sleep(1200)` (Shaheen step 2)
  3. `dishareTransport.fastCast(pkg, tag)` →
     `bindApi → register → setVideoSize → setGestureShare(true) →
     quickShare(tag)` (Shaheen `fireDiShare`)
- **`ShellLaunch` →** `dispatchShellLaunch(pkg, displayId)` on
  `adbExecutor`, faithful port of Shaheen `launchCluster`:
  - resolve `component = getLaunchIntentForPackage(pkg).component
    .flattenToShortString()`
  - `cmd = "am start -S --display $displayId
    --activity-multiple-task --activity-clear-top -n $component"`
  - **verify-then-retry ×3**: `AdbShellBridge.shell(cmd)` → sleep
    900 ms → `AmStackParser.parseAll(AdbShellBridge.shell(
    amStackList()))` → `findOnDisplay(rows, pkg, displayId) != null`?
    landed : retry. Handles the display-group re-home (Small Panel
    flakiness).

## `DishareTransport` — the protocol fixes

- **Opcodes** back to ground truth: `OP_REGISTER=1`,
  `OP_QUICK_SHARE=8`, `OP_SET_GESTURE_SHARE_ENABLED=9`,
  `OP_SET_VIDEO_SIZE=11`.
- **`clientBinder.onTransact`**: `code==1` → drain+`readInt`+`true`;
  `code==IBinder.INTERFACE_TRANSACTION` →
  `reply?.writeString(CLIENT_IFACE)`+`true`; else
  `super.onTransact`. *(the fix that made DiShare accept our client)*
- **`transact()`**: `b.transact(code,data,reply,0)` →
  `reply.readException()` (propagate) → `return true`. **No
  `readInt`.** Matches Shaheen `txn`.
- Swipe / `MultiTouchInjector` / `ControlSession` purge / the
  "corrected 7/8/5/15 opcodes" — all **reverted/removed** (wrong turns).

## What's proven vs unproven

| Item | State |
|---|---|
| Detection → `l5` → `LEOPARD5_PROFILE` | ✅ proven on-car |
| DiShare binder protocol (opcodes + cb binder + reply) | ✅ proven — DiShare's own `DiShareApiServiceImpl` log acks us by package |
| `ShellLaunch` planner routing + verify-retry + tests | ✅ implemented, `DisplayLaunchPlannerTest` updated |
| FSE foreground+1200 ms+quickShare sequence | ✅ implemented (matches Shaheen) — visible-cast not yet confirmed |
| Cluster app actually lands on display 3/4 | ❌ **not reproduced** — apps stay on display 0 in our tests (see [07](./07-open-issues-and-diagnostics.md)) |

## Synthetic FSE / passenger surface — SINGLE SOURCE

`android/app/src/main/kotlin/com/i99dev/ilink/display/DisplayPlatformPlugin.kt`
(`snapshotList()` + `syntheticFseMap()`)

The OS does not reliably enumerate the FSE surface (display 2,
`fission_bg_XDJAScreenProjection`) to a non-owner app via
`DisplayManager.getDisplays()` — it is owner-exclusive to
`com.byd.containerservice` and its visibility is **volatile** (it
appears/disappears with DiShare/container state). When absent, an
enumeration-driven picker would have **no passenger target at all**.

The synthetic FSE display is injected **once, at the single source
of truth — `DisplayPlatformPlugin.snapshotList()`** (the one
`display.list` that the slide-panel app picker, the mini-app actions
sheet, the SDK, and the event-channel snapshot all read). It is
**NOT** re-derived in any per-UI Dart provider — doing that diverges
the lists (the audit-D1 anti-pattern). `_picketDisplaysProvider`
just consumes the centralized list (`list.forPicker()`); no
injection there.

`syntheticFseMap()` builds a wire map shaped exactly like
`displayToMap()` (id `2` = `DishareTransport.DISPLAY_ID_FSE`, role
`passenger`, `overrideLabel` from the active profile, 1920×720). It
is appended **iff** `carProfile.capabilities.passenger ==
PassengerTransport.DishareQuickShare` (the exact same boolean the
launch transport forks on, so the list and the transport can never
disagree) **and** display 2 isn't already enumerated (**idempotent**
— OS-enumerated display 2 wins, no duplicate). The drop drives the
existing path: `pkg.launch(displayId:2,targetRole:passenger)` →
planner → `LaunchPlan.Dishare("fse")` (`DeviceTagResolver` maps
displayId 2 → `fse` from the profile) → `dispatchFastCast`
(foreground-on-IVI → 1200 ms → quickShare). Mirrors the reference
launcher's fixed-target `Targets.FSE` model.

**Scalability/maintenance:** a new Di5.0 trim needs zero picker code
— it sets `capabilities.passenger = DishareQuickShare` in its
`CarProfile` and the FSE card + transport both follow. One source,
profile-driven, computed once per snapshot natively (not per Dart
consumer).

**On-car verified 2026-05-18:** picker renders Head Unit / Small
Panel / Driver Dashboard / FSE (real display-2 card when the OS
enumerates it, synthetic "FSE Co-pilot" when it doesn't) — and the
mini-app sheet / SDK now see the identical list.

## Other (unrelated, kept)

`lib/features/home/presentation/widgets/display_drop_picker.dart` —
`_flashAndClear` linger-unmount fix (clear the drag controller before
the `mounted` guard) so a card unmount during the success-flash can't
jam the picker open. Independent of DiShare; correct; keep.

## Build and device verification

Use the current RELEASE.md procedure and the original external signing identity. Historical tunnel addresses and install commands are not valid targets. Identify and authorize a safe head unit before any install or actuator test.
