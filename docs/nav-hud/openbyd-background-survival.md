# How OpenBYD's nav→cluster pipeline survives backgrounding — mechanism-by-mechanism

**Task:** TASK-020 · **Status:** research only, **no production code changed** ·
**Date:** 2026-07-20 · **Branch:** `feat/openbyd-background-survival`

## 0. Rules this document was written under

Every claim below cites either a `file:line` in the decompiled OpenBYD 2.4.2.1 tree or a
`file:line` in `car-ilink`. Where neither source settles a question the row says
**UNKNOWN** and names the probe that would settle it. There are no "likely"/"probably"
rows. A grounded UNKNOWN is the intended output, not a failure.

**Sources.**

- Decompile: `<scratch>/openbyd2421/sources/com/sr/openbyd/…`, verified intact by file
  count (7218 files), consistent with the count recorded in `TASK-020.md:42`.
- Manifest + resources: `<scratch>/openbyd2421_apktool/` (apktool 2.9.3; jadx's manifest
  rendering is lossy). Paths below are relative to those two roots.
- Ours: paths relative to the `car-ilink` repo root.

**Their source and assets are not in this repo and must not be.** Only mechanism and
interface facts are recorded here.

---

## 1. What the bug is, stated precisely

The maneuver/direction arrow stops updating on the cluster when **our** app is
backgrounded. OpenBYD, running on the same cars, does not exhibit this.

The pipeline has three separable stages, and "the arrow stopped" can be any of them:

1. **Ingest** — reading distance/road/maneuver out of the nav app (a11y tree, or the
   nav notification).
2. **Orchestrate** — turning frames into pushes (coalescing, keepalive re-push).
3. **Transport** — the binder/HAL write that paints the cluster.

Stage 3 keeps painting the *last* value on both sides even with no new input (their
200 ms keepalive, §2 M6; our 1 s tick, §3 M6), so "arrow frozen but present" points at
stage 1 or 2, and "arrow gone" points at stage 3 or a teardown. **The reported symptom is
"stops updating", i.e. frozen, not blank** — that is the discriminator used in §4.

---

## 2. Their mechanism set, enumerated from their code first

This section deliberately does not look at our code. It is the complete set of things
OpenBYD does that bear on staying alive and staying fed while its own UI is not on screen.

| # | Mechanism | Cite | What it actually does |
|---|---|---|---|
| M1 | `ClusterProjectionService`, `foregroundServiceType="specialUse"` | `AndroidManifest.xml:49-51` | Declared FGS with the purpose string *"Projecting navigation and apps to the instrument cluster display."* |
| M1a | `startForeground` is called in `onCreate`, **before any work**, and the service does no work | `services/ClusterProjectionService.java:50-54` | `onCreate` → `createNotificationChannel()` → `startForeground(101, …)`. The class has **no** nav code, no binder, no timer. `onBind` returns null (`:45-47`). |
| M1b | `onStartCommand` returns `1` (`START_STICKY`) | `services/ClusterProjectionService.java:63-65` | System restarts it if killed. |
| M1c | Notification is `NotificationChannel(…, 2)` = IMPORTANCE_LOW, `flags |= 2` (`FLAG_ONGOING_EVENT`), priority `-1` | `services/ClusterProjectionService.java:29-30,37` | Silent ongoing notification. |
| M1d | **It is started only by the app-casting feature, never by the HUD** | started at `ui/overlay/ClusterOverlayManager$castAppToCluster$1.java:127` and `:186`; stopped at `ui/overlay/ClusterOverlayManager.java:706` (inside `hideOverlay`) | Exhaustive grep for `ClusterProjectionService` across `com/sr/openbyd` returns only these call sites plus its own file. **No nav/HUD class references it.** |
| M1e | `onDestroy` tears down the overlay | `services/ClusterProjectionService.java:57-60` | `ClusterOverlayManager.hideOverlay` — again, casting, not nav. |
| M2 | Nav ingest entry point #1: `BydAccessibilityService.onAccessibilityEvent` | `services/BydAccessibilityService.java:837-863` | System-bound service. Reads `AppPrefs/hud_integration_enabled`, routes by selected nav app to `handleWazeEvent`/`handleGoogleMapsEvent`/`handleYandexEvent`. **No Activity involvement.** |
| M2a | Background window read: event source → **all displays** → active window | `services/BydAccessibilityService.java:95-144`; `getWindowsOnAllDisplays()` at `:104`; `getRootInActiveWindow()` at `:131`; **dispatch gate** at `:842-861` | `getRootNodeForPackages()` runs this three-rung ladder **unconditionally once it is called** — it does not itself check which window is focused, so a map that is not the focused window is still read. ⚠️ **CORRECTED (TASK-021/TASK-022):** this row previously said the ladder runs "on **every** event". That is imprecise. `onAccessibilityEvent` (`:842-861`) routes to a handler **only when the event's own package is the currently selected nav app** — `str.equals(WAZE_PACKAGE)` (`:853`), `MAP_PACKAGES.contains(str)` (`:857`), `YANDEX_PACKAGES.contains(str)` (`:859`), where `str` is the **event's** package (`:842-845`). A foreign package matches no branch, reaches no handler, and so **never** runs the ladder. The unconditionality is *within* the ladder, not *across* packages. Consequence for us: our `pkg !in active` early-return is **not** a divergence from the reference, and was therefore kept verbatim as `NavA11yReadPolicy.isNavEvent` rather than widened. |
| M2b | Same ladder exposed as a visibility predicate | `services/BydAccessibilityService.java:791-834` | `isPackageVisible()` — all-displays scan, then active window. |
| M2c | a11y flags re-asserted at runtime | `services/BydAccessibilityService.java:915-920` | `serviceInfo.flags |= 96` = `0x20 | 0x40` = `FLAG_REQUEST_FILTER_KEY_EVENTS | FLAG_RETRIEVE_INTERACTIVE_WINDOWS`. The latter is what makes M2a legal after a ROM rebind. |
| M2d | a11y static config | `res/xml/accessibility_service_config.xml` | `accessibilityEventTypes="typeAllMask"`, `accessibilityFlags="flagReportViewIds|flagRequestFilterKeyEvents|flagRetrieveInteractiveWindows"`, `canRetrieveWindowContent="true"`, `canRequestFilterKeyEvents="true"`. **No `packageNames`** (all apps) and **no `notificationTimeout`** (default 0 = no event coalescing delay). |
| M2e | Per-app read throttle, 200 ms | `services/BydAccessibilityService.java:229` (Maps), `:477` (Waze), `:644` (Yandex) | `currentTimeMillis - lastXRead < 200 → return`. |
| M2f | Handled event types | `services/BydAccessibilityService.java:227,475,640` | `2048` (`TYPE_WINDOW_CONTENT_CHANGED`) and `32` (`TYPE_WINDOW_STATE_CHANGED`) only. |
| M2g | Service instance is a **process-static volatile** | `services/BydAccessibilityService.java:46-47`, set at `:911`, cleared at `:866-872` | `instance` / `isConnected` are class statics. |
| M3 | Nav ingest entry point #2: `MapNotificationListenerService` | `AndroidManifest.xml:53-57`; `services/MapNotificationListenerService.java:68+` | System-bound notification listener; parses `android.title` / `android.text` / `android.subText` off ongoing (`flags & 2`) nav notifications. |
| M3a | De-dupes on the three text fields; only dispatches on change | `services/MapNotificationListenerService.java:112-116` | Guards against re-processing an identical post. |
| M3b | Listener disconnect **ends** navigation | `services/MapNotificationListenerService.java:59-65` | `onListenerDisconnected` → `HudController.closeNavigation(applicationContext)`. |
| M3c | Also a process-static volatile instance | `services/MapNotificationListenerService.java:22`, `:39`, `:47-50` | |
| M4 | **All pipeline state is process-static; nothing is owned by an Activity** | `services/HudController.java:99-101` (`currentStrategy` static, `INSTANCE` static singleton); `proxy/ProxyManager.java:28-35` (five statics incl. `carControl`); `services/strategies/SomeIpHudHelper.java:55-56,107` (`sAppContext`, `sOverridePng`, `sOverrideHudId` static) | The object graph that drives the cluster is reachable from any component in the process without an Activity. |
| M5 | `MainActivity` overrides **only** `onCreate` | `MainActivity.java:131-132`; grep for `onPause|onStop|onResume|onDestroy|onTrimMemory` in that file returns only `onCreate` hits | There is no teardown path tied to the UI at all. Activity death is a non-event for the pipeline. |
| M5a | `MainActivity` manifest attributes are all defaults | `AndroidManifest.xml:24-29` | No `launchMode`, no `taskAffinity`, no `resizeableActivity`. |
| M6 | **200 ms keepalive coroutine re-firing the last frame** | `services/strategies/SomeIpHudHelper.java:155-163` (`startKeepAliveJob`); delay literal `200L` at `services/strategies/SomeIpHudHelper$startKeepAliveJob$1.java:70`; body `sendKeepAliveUpdate` at `SomeIpHudHelper.java:139-153` | Loops `sendKeepAliveUpdate()` → 200 ms → repeat, on a scope owned by the `SomeIpHudHelper` instance (`:104,161`), which lives on `CanBydFidStrategy` (`:34`), which lives in the static `HudController.currentStrategy`. Not on the main thread, not on the Activity. |
| M6a | Keepalive gate | `services/strategies/SomeIpHudHelper.java:142` | Returns early unless `activeContext != null && lastNavigationData != null && isNavigationRunning && binder != null && HudController.isHudActive()`. |
| M6b | Keepalive **re-reads position** every tick | `services/strategies/SomeIpHudHelper.java:145` | `LocationHelper.INSTANCE.updateVehicleLocation(context)` before re-emitting. |
| M6c | Keepalive increments the rolling counter | `services/strategies/SomeIpHudHelper.java:152` | `counter = (counter + 1) & 255` — the cluster sees a *fresh* frame, not a byte-identical repeat. |
| M7 | Self-healing vendor bind | `services/strategies/SomeIpHudHelper.java:958-979`, rebind at `:972-974` | `updateNavigation` — if `binder == null`, call `bind(context)` and **return** (skip this frame); the next frame flows once bound. |
| M7a | Bind uses `applicationContext` | `services/strategies/SomeIpHudHelper.java:191` | `context.getApplicationContext().bindService(...)`, so the binding is not scoped to an Activity. |
| M7b | Explicit-component fallback bind | `services/strategies/SomeIpHudHelper.java:196-198` | If the action-intent bind fails on the UI7 strategy, retry with `ComponentName(PKG, COMPONENT_CLASS)`. |
| M7c | On (re)connect, **re-start every service id** if nav is running | `services/strategies/SomeIpHudHelper.java:60-97`, loop at `:85-88` | `ServiceConnection.onServiceConnected` re-issues `startSomeIpService(id)` for the active strategy. This is the recovery path after a vendor-service restart. |
| M7d | Unbind only on explicit stop | `services/strategies/SomeIpHudHelper.java:898-913` (`stopNavigation`), `:945-956` (`unbind`) | Nothing lifecycle-driven unbinds. |
| M8 | Second, always-on output: BYD Amap broadcast, tagged **not foreground** | `services/HudController.java:435-457`, broadcast built at `:151-221`, `EXTRA_IS_FOREGROUND` set to `0` at `:161` | Fired alongside the primary transport on every `updateNavigation`, gated on `AppPrefs/hud_amap_broadcast_enabled` (default **true**, `:447`). Broadcast is sent three ways: to `com.byd.amapservice`, to `com.example.amapservice`, and unpackaged (`:205-211`). |
| M9 | `HudController` is re-entrant and self-starting | `services/HudController.java:106-117`, `:431-433`, `:459-462` | `getStrategy()` lazily constructs `CanBydFidStrategy` on first use; `isHudActive()` is just `currentStrategy != null`. `updateNavigation` needs no prior `arm()`. |
| M9a | `SomeIpHudHelper.updateNavigation` self-starts navigation | `services/strategies/SomeIpHudHelper.java:961-963` | `if (!isNavigationRunning) startNavigation(context)` — which binds and starts the keepalive (`:849-866`). |
| M9b | `ensureHudActive()` can run with **no Context at all** | `services/HudController.java:287-324` | Reflects `ActivityThread.currentApplication()`, falling back to `ActivityThread.systemMain().getSystemContext()` wrapped so `getSharedPreferences` still resolves. Explicitly designed to work from a context-less callsite. |
| M10 | Boot revival | `AndroidManifest.xml:42-48`; `receiver/BootReceiver.java` | `BOOT_COMPLETED` + `QUICKBOOT_POWERON`, `priority="1000"`, `goAsync()`, sets `AppPrefs/run_startup_on_connect=true` and launches the proxy. |
| M11 | **No `WAKE_LOCK` permission and no wake-lock code** | absent from `AndroidManifest.xml:2-22`; grep for `WakeLock|PowerManager` across `com/sr/openbyd` returns **zero** hits | They do not hold the CPU awake. |
| M12 | **No `onTrimMemory` / `onLowMemory` anywhere** | grep across `com/sr/openbyd` returns zero hits | No memory-pressure handling. |
| M13 | No `AlarmManager` / `JobScheduler` / `WorkManager` | grep across `com/sr/openbyd` returns zero hits | No scheduled revival beyond M1b and M10. |
| M14 | `WazeArrowCaptureService`, `foregroundServiceType="mediaProjection"` | `AndroidManifest.xml:52` | Waze arrow pixels. |
| M15 | `SYSTEM_ALERT_WINDOW` overlay | `AndroidManifest.xml:4`; `ui/overlay/ClusterOverlayManager.java` | Used by the cast/overlay feature (`hideOverlay` at `:693-712`, `launchOnVirtualDisplay` at `:716+`), not by the HUD. |
| M16 | `CaptureRequestActivity` is `singleInstance` + `excludeFromRecents` + `taskAffinity=""` + translucent | `AndroidManifest.xml:30` | The consent shim is deliberately kept out of the app's own task. |

### 2.1 The finding that kills the obvious conclusion

**M1d is the important row.** `ClusterProjectionService` is a *casting* anchor, not a nav
anchor: its only two start sites are inside `castAppToCluster`, its stop site is inside
`hideOverlay`, and its own body contains no navigation code whatsoever
(`services/ClusterProjectionService.java:17-86` in full). OpenBYD's HUD runs with that
service **not running at all**.

So "OpenBYD has a nav foreground service and we don't" is **false as stated**. What
OpenBYD actually has is M2+M3+M4+M6: two *system-bound* services as the ingest sources,
a fully process-static object graph, and a 200 ms self-driven keepalive — none of which
require an Activity, and none of which require an FGS.

---

## 3. Ours, checked against that list, one row at a time

| # | Their mechanism | Ours | Verdict |
|---|---|---|---|
| M1 | Nav-purpose FGS | **ABSENT as a nav FGS.** Our only nav-adjacent FGS is `WazeArrowCaptureService` (`android/app/src/main/AndroidManifest.xml:384-386`, `startForeground` at `nav/ingest/WazeArrowCaptureService.kt:162,164`). **But** we run an always-on process anchor: `ConnectivityService`, `foregroundServiceType="specialUse"`, subtype `online_presence_keepalive` (`AndroidManifest.xml:323-325`, `startForeground` at `connectivity/ConnectivityService.kt:293,299`), whose manifest comment states its job verbatim: *"Anchors the process at foreground-service priority so the head unit's standby memory reclaim can't kill us"* (`AndroidManifest.xml:309-313`). Additionally `MainActivity.onStop()` starts `BubbleOverlayService` (specialUse FGS) on every user-initiated background (`MainActivity.kt:505-510` → `:519-531`; service at `AndroidManifest.xml:346-348`). | **NO ACTIONABLE DELTA.** They have no nav FGS either (M1d). We have *more* process anchoring than they do, from two independent specialUse FGSs. Adding a third would change nothing about who feeds the pipeline. |
| M1b | `START_STICKY` on the nav FGS | N/A — no nav FGS on either side. | Not applicable. |
| M2 | a11y as ingest entry, system-bound, Activity-independent | Present: `input/RemoteControlAccessibilityService.kt:197-208` (`onAccessibilityEvent`) → `nav/ingest/NavA11yDispatcher.kt:32-37` → `nav/ingest/A11yNavSource.kt:68`. Declared at `AndroidManifest.xml:569`, **no `android:process`** ⇒ same process. | **PARITY at the service level.** See M4 for what differs. |
| M2a | All-displays background read on **every event** | Present but **only on the 600 ms poll, never on the event path.** `readBackgroundNavWindows()` (`RemoteControlAccessibilityService.kt:239-255`, `windowsOnAllDisplays` at `:242`) is called from exactly one place: `navPoll` at `:109-111`, and only when the foreground package is **not** a registered nav app. `onAccessibilityEvent` (`:197-208`) uses `rootInActiveWindow` only (`:201`) and returns early when `pkg !in active` (`:200`). | **REAL DELTA, but it favours neither side cleanly, and it is NARROWER than this row first claimed.** ⚠️ **CORRECTED (TASK-021/TASK-022):** their ladder is *not* "per-event and unconditional" across packages — `onAccessibilityEvent:842-861` gates on the event's package being the selected nav app (see §2 M2a). So the `pkg !in active` early-return is **not** the delta; the real delta is only that their ladder runs on the **event path** while ours runs solely on the **600 ms poll**. That is what TASK-021 actually fixed (`179c3896`): the event path now falls through to the ladder behind a shared 200 ms gate, with the package guard preserved. Ours is also API-30-gated (`:240`). See §4-C. |
| M2c | `serviceInfo.flags |=` re-assert of `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` at connect | We re-assert `FLAG_REQUEST_MULTI_FINGER_GESTURES | FLAG_REQUEST_FILTER_KEY_EVENTS` (`RemoteControlAccessibilityService.kt:140-146`) — **not** `FLAG_RETRIEVE_INTERACTIVE_WINDOWS`. We do read-modify-write (`info = serviceInfo; info.flags = info.flags or …; serviceInfo = info`), so the XML flag is preserved *if the ROM supplied it in `serviceInfo`*. It is declared in XML at `res/xml/a11y_remote_control.xml` (`flagRetrieveInteractiveWindows`). | **DELTA — CLOSED in code (`b2396469`), consequence still unproven.** Their comment-free `\|= 96` is exactly the defensive re-assert we did *not* do for this flag; we now do. ⚠️ **TASK-022 (`840cbb47`) also added `FLAG_REPORT_VIEW_IDS` (0x10)**, which is the *symmetric* case: equally XML-only, equally un-re-asserted, and it backs the **entire** scrape (`findAccessibilityNodeInfosByViewId`, `A11yNavSource.kt:114`). Without it the ladder can succeed and still emit zero frames — a freeze **indistinguishable** from a missing 0x40, which would let a car session wrongly rule out Candidate B. Whether a BYD ROM ever drops either flag remains **UNKNOWN** — probe in §5-P3. Prior evidence favours "not dropped" for 0x10: the reference relies on view-id lookups in **124** places while never re-asserting it, and its HUD works. That inference does **not** transfer to 0x40, which the reference *does* defend. |
| M2d | `typeAllMask`, no `packageNames`, **no `notificationTimeout`** | `res/xml/a11y_remote_control.xml`: `typeWindowStateChanged|typeWindowsChanged|typeViewFocused|typeWindowContentChanged`, no `packageNames`, **`notificationTimeout="100"`**. | **PARTIAL DELTA, benign for nav.** Our event set is a superset of the two types they actually handle (M2f: 2048 + 32). `notificationTimeout=100` coalesces same-type events into at most one per 100 ms — strictly finer than their own 200 ms self-throttle (M2e), so it cannot be the limiter. |
| M2e | 200 ms per-app read throttle | `nav/ingest/A11yNavSource.kt:44` (`throttleMs = 200L`), enforced at `:69-71`. | **PARITY (exact).** |
| M3 | Notification listener as second ingest | Present: `nav/ingest/NavNotifListenerService.kt`, declared `AndroidManifest.xml:371`. | **PARITY.** |
| M3a | De-dupe on change | We do **not** de-dupe; we do the opposite — a 700 ms `keepFresh` ticker re-processes every present nav notification (`NavNotifListenerService.kt:32-40`, cadence `:125`). | **DELTA in our favour.** Ours is strictly fresher than theirs on this path. |
| M3b | Listener disconnect ends navigation | `onListenerDisconnected` only stops the ticker (`NavNotifListenerService.kt:48-51`); it does **not** clear the cluster. The controller's `ABANDON_MS = 45_000L` backstop covers it (`nav/controller/HudController.kt:280,202`). | **DELTA, harmless direction.** We hold the last frame longer than they do. Not a "stops updating" cause. |
| M4 | **Process-static pipeline, no Activity ownership** | **INVERTED.** Our whole pipeline is an Activity-scoped object graph: `MainActivity.onCreate` → `PlatformPlugins.installAll` → `NavHudPlatformPlugin(applicationContext, messenger)` (`PlatformPlugins.kt:88`). `HudController`, the transport list, the source list and `NavSourceRegistry` are all **instance fields** of that plugin (`nav/NavHudPlatformPlugin.kt:71-82,89-135`). Teardown: `MainActivity.onDestroy()` → `platformPlugins?.disposeAll()` (`MainActivity.kt:533-539`, call at `:536`) → `navHud::dispose` (`PlatformPlugins.kt:103`) → `registry.stop()` + `controller.dispose()` (`NavHudPlatformPlugin.kt:306-311`) → `HudController.dispose()` = `disarm()` (`nav/controller/HudController.kt:274`). | **THE STRUCTURAL DELTA.** See §4-A. |
| M4a | Static instance survives, sources keep dispatching | `registry.stop()` calls `source.stop()` on every source (`nav/ingest/NavSourceRegistry.kt:50-55`), and `A11yNavSource.stop()` calls `NavA11yDispatcher.unregister(this)` (`nav/ingest/A11yNavSource.kt:63-66`). With the handler list empty, `NavA11yDispatcher.activePackages` is empty (`NavA11yDispatcher.kt:28-29`), so both the event path (`RemoteControlAccessibilityService.kt:200`) and the poll (`:84-85`, `:109`) **short-circuit to a no-op**. | **THE MECHANISM OF THE FAILURE, if the Activity is destroyed.** The a11y service stays alive and bound; it just has nowhere to deliver. |
| M5 | `MainActivity` has no lifecycle overrides at all | We override `onPause` (`MainActivity.kt:475`), `onUserLeaveHint` (`:492`), `onStop` (`:505`), `onDestroy` (`:533`). **Only `onDestroy` touches the plugins** (`:536`); `onPause`/`onStop` do not. | **DELTA scoped to Activity destruction.** Plain backgrounding (resumed→stopped) does **not** disarm. |
| M5a | Default `MainActivity` manifest attributes | `launchMode="singleTask"`, `taskAffinity="com.i99dev.ilink"`, `resizeableActivity="false"` (`AndroidManifest.xml:186-190`). | **DELTA, relevance UNKNOWN.** These affect task routing, not pipeline liveness, on any reading I can source. Kept in the table because §6 (prior art) shows single-task interaction has already caused one on-car regression. |
| M6 | 200 ms keepalive re-push, counter-incrementing, position-refreshing | Present but **5× slower**: `HudController` `tickIntervalMs = 1_000L` (`nav/controller/HudController.kt:43`), tick at `:193-216`, re-push at `:212`. Counter increments per push (`:184`). We additionally **extrapolate the distance down** between source frames (`:225-235`) — they do not. | **DELTA (cadence), plus a capability they lack.** 1 s vs 200 ms. Whether the BYD cluster's own auto-hide tolerates 1 s is **UNKNOWN** — but it is not a *background-specific* delta: the cadence is the same foreground and background, and the arrow is reported as working in foreground. |
| M6a | Keepalive gate `isNavigationRunning && binder != null && isHudActive` | `tick()` gates on `armed` + `lastFrame != null` + `activeTransports.isNotEmpty()` (`HudController.kt:194-196`). Transport-level liveness is not part of the gate; a throwing transport is swallowed per-push (`:187`). | **PARITY in spirit.** |
| M6b | Position refreshed on every keepalive tick | Position is stamped **only** on a real source frame, in `NavSourceRegistry.onFrame()` (per `CLAUDE.md:130-136`); the keepalive re-pushes `lastFrame` unchanged apart from extrapolated distance (`HudController.kt:212,225-235`). | **DELTA, deliberate.** `NavGuidanceCoalescer.changed()` is an allow-list that deliberately excludes position so a drifting fix cannot push on its own (`CLAUDE.md:138-141`). Do not "fix" this to match them. |
| M7 | Self-healing rebind inside the update path | `HudController.onFrame` re-selects transports only when the list is **empty** (`HudController.kt:156`); `pushFrame` swallows a throwing transport and keeps feeding it later frames (`:183-191`). There is no explicit "binder null → rebind → skip frame" rung at the controller. | **DELTA, location unknown.** Whether `SomeIpHudTransport` rebinds internally was **not read in this task** — see §5-P4. |
| M7c | Re-issue `startSomeIpService` for every id on reconnect | Our transport iterates `variant.serviceIds` on `start`/`stop` (`CLAUDE.md:86-89`). Whether that re-runs on a *reconnect* was not verified. | **UNKNOWN** — §5-P4. |
| M8 | Amap broadcast fan-out with `EXTRA_IS_FOREGROUND=0`, default on | Present as an aux transport driven on every push regardless of protocol override: `AmapBroadcastTransport` in `auxTransports` (`nav/NavHudPlatformPlugin.kt:79-81`), fanned out at `HudController.kt:189`. Self-gates on `NavHudOptions.amapWidget`. | **PARITY at the architecture level.** Whether our broadcast sets `EXTRA_IS_FOREGROUND=0` was **not verified in this task** — §5-P5. |
| M9 | Pipeline self-starts on first frame, no `arm()` required | **INVERTED.** `HudController.submit()` returns immediately when `!armed` (`HudController.kt:125`); `registry.start()` is the only thing that arms (`NavSourceRegistry.kt:40-48`), reached only via `armHud()` (`NavHudPlatformPlugin.kt:152-156`) from the `arm` channel call or the constructor's auto-arm thread (`:144-146`). | **DELTA.** Ours has an explicit armed state that a teardown can leave `false`; theirs cannot be "disarmed" by anything except an explicit `closeNavigation`. |
| M9b | `ensureHudActive()` works with no Context, via `ActivityThread` reflection | **ABSENT.** Every entry to our pipeline needs the plugin instance. | **DELTA, downstream of M4.** They built an explicit escape hatch for exactly the "no Activity, no Context" case. |
| M10 | `BOOT_COMPLETED` + `QUICKBOOT_POWERON` @1000 revival | Not audited in this task (we have `boot/BootPlatformPlugin.kt` and a resume watchdog referenced at `AndroidManifest.xml:330+`). | **UNKNOWN, out of scope** — boot is not backgrounding. |
| M11 | No `WAKE_LOCK`, no wake-lock code | We declare `WAKE_LOCK` (`AndroidManifest.xml:71`) but the manifest comment attributes it to `just_audio_background`'s `AudioService` (`:63-67`), and grep for `WakeLock|PowerManager` across `android/app/src/main/kotlin/com/i99dev/ilink/` returns **zero** hits. | **NO DELTA.** Neither side holds a wake lock in its own code. This row exists to close the question, not because it matters. |
| M12 | No `onTrimMemory` | Grep across our kotlin tree returns **zero** hits. | **PARITY.** |
| M13 | No Alarm/Job/Work scheduling for the pipeline | Not audited beyond the grep in M11/M12. | **UNKNOWN, low value.** |
| M14 | Waze arrow via mediaProjection FGS | Present (`AndroidManifest.xml:384-386`). | **PARITY.** |
| M15 | Overlay used for casting only | We have overlay FGSs (`BubbleOverlayService`, `AppShortcutOverlayService`) unrelated to nav. | **NO DELTA for nav.** |
| M16 | Consent shim isolated in its own task | `WazeCaptureConsentActivity` exists (`nav/ingest/WazeCaptureConsentActivity.kt`); its manifest attributes were **not verified in this task**. | **UNKNOWN, out of scope.** |

**Row count: 30 comparison rows. 24 cited on both sides. 6 UNKNOWN or explicitly
out-of-scope** (M2c consequence, M7/M7c rebind behaviour, M8 broadcast field, M10, M13,
M16). Two further rows (M5a, M6 cadence) are cited on both sides but their *consequence*
is unproven and labelled as such.

---

## 4. Root-cause statement

### It is not determinable from source alone which delta is active. Three candidates survive the table, and they are distinguishable by one cheap on-car observation.

The reason a single answer cannot be given from source is that "the arrow stops updating
when the app is backgrounded" is consistent with all three, and our own code contains a
**different** failure for each:

#### Candidate A — Activity destruction disarms the pipeline (M4 + M4a + M9)

This is the only *structural* inversion in the table, and it is fully cited:

`MainActivity.onDestroy()` → `disposeAll()` (`MainActivity.kt:536`) → `navHud.dispose()`
(`PlatformPlugins.kt:103`) → `registry.stop()` + `controller.dispose()`
(`NavHudPlatformPlugin.kt:306-311`) → `A11yNavSource.stop()` →
`NavA11yDispatcher.unregister` (`A11yNavSource.kt:63-66`) → `activePackages` empty
(`NavA11yDispatcher.kt:28-29`) → the a11y event path (`RemoteControlAccessibilityService.kt:200`)
and the 600 ms poll (`:84-85`) both become no-ops → `HudController.disarm()` clears the
cluster and quits the `nav-hud` thread (`HudController.kt:107-121`).

OpenBYD cannot experience this: its Activity overrides nothing but `onCreate` (M5) and its
pipeline is static (M4).

**Crucially, this does NOT fire on plain backgrounding** — `onPause` and `onStop` do not
touch the plugins (`MainActivity.kt:475-478`, `:505-510`). It fires when the ROM *destroys*
the backgrounded Activity while the process survives (our process survives readily: two
specialUse FGSs, M1). **Predicted signature: the arrow goes BLANK and never returns until
the user reopens the app.** `disarm()` calls `it.clear()` on every transport
(`HudController.kt:113`).

#### Candidate B — ingest starves because no nav app has a readable window (M2a)

If neither our app nor the map is foreground (e.g. the BYD launcher is), the event path is
dead by construction — `onAccessibilityEvent` only fires for packages in `activePackages`
(`RemoteControlAccessibilityService.kt:198-200`) — and everything rests on the 600 ms poll's
`readBackgroundNavWindows` (`:109-111`, `:239-255`). That path finds nothing for an app that
keeps no window when backgrounded. Commit `e9835e25` states this outcome for Waze
explicitly: *"Waze (no usable notif, no background window) is foreground-only"*.

**Predicted signature: the arrow FREEZES at its last value** — `HudController.tick()`
keeps re-pushing `lastFrame` with an extrapolated distance for up to `ABANDON_MS = 45 s`
(`HudController.kt:202,212,280`), then clears.

#### Candidate C — the frame is fresh but the maneuver provider is stale

The maneuver on Maps/Yandex does not come from a11y at all; it comes from
`NavManeuverBus` via the notification (`NavHudPlatformPlugin.kt:112-116,130`,
`A11yNavSource.kt:87-88`), read with a TTL window (5 s Maps, 10 s Yandex). Distance/road
can keep updating from the notification path (`NavNotifListenerService.kt:32-40`) while the
**arrow** falls back to `ManeuverCatalog.STRAIGHT` once the bus entry ages out
(`A11yNavSource.kt:88`). For Waze the arrow additionally requires MediaProjection capture,
which `WazeCaptureGate.onWazeGone` releases when Waze is not foreground
(`RemoteControlAccessibilityService.kt:97`).

**Predicted signature: distance keeps counting down but the arrow goes STRAIGHT/wrong**
— i.e. the *arrow specifically* stops updating while the rest of the frame does not. Note
this matches the literal wording of the bug report ("the maneuver/direction arrow") more
closely than A or B do.

### The discriminator

These three produce three different, mutually exclusive on-car pictures:

| Candidate | Distance field | Road field | Arrow |
|---|---|---|---|
| A (disarm) | blank | blank | blank |
| B (ingest starved) | frozen, then blank after ~45 s | frozen | frozen |
| C (maneuver TTL) | **still counting down** | still updating | wrong/straight |

**A 10-second look at the cluster settles it.** No instrumentation needed.

### What is definitely NOT the root cause

- **"We lack `ClusterProjectionService`."** M1d: theirs is a casting anchor with zero nav
  code, started only from `castAppToCluster` and stopped from `hideOverlay`. Their HUD runs
  with it stopped.
- **"Our process gets frozen/reclaimed for lack of an FGS."** M1: we run
  `ConnectivityService` (specialUse, always-on, purpose-built as a process anchor,
  `AndroidManifest.xml:309-326`) plus `BubbleOverlayService` started on every
  `onStop` (`MainActivity.kt:505-510`). We are *more* anchored than OpenBYD, which runs
  no FGS at all on the HUD path.
- **"We lack a keepalive."** M6: we have one, at 1 s instead of 200 ms, plus distance
  extrapolation they lack.

---

## 5. Probes — what would settle each UNKNOWN

Ordered by value. All are read-only; none require a code change.

- **P1 (settles A vs B vs C, highest value).** With nav running, background the app for
  ~60 s and read the cluster against the discriminator table in §4. Then
  `adb shell dumpsys activity activities | grep -i ilink` to confirm whether
  `MainActivity` still exists in the task record. If the Activity is gone **and** the
  cluster is blank ⇒ Candidate A, confirmed end to end.
- **P2 (settles A independently of the display).** `adb shell dumpsys activity services
  com.i99dev.ilink` before and after backgrounding, plus the plugin's own `status`
  channel call (`NavHudPlatformPlugin.kt:209-230`) which returns `armed`. If `armed`
  flips `true`→`false` without a `disarm` from the UI, Candidate A is proven.
- **P3 (settles M2c — REWRITTEN by TASK-022; the old one-bit version was not decisive).**

  This probe previously said "check bit `0x40`". Two problems, both now fixed in code
  (`10e737f9`), and the old version should not be used:

  1. Our flags log printed the word **after** the OR — so it always showed the bits we had
     just set and **could never reveal a drop**. Only the **pre-OR** word is informative.
  2. It was `Log.i`, which release **strips** (`proguard-rules.pro:247-252`), so it did not
     exist on the prod build that goes in the car. It is now `Log.w`, which survives.

  **Read the WHOLE flags word, not one bit** — one reading then answers every dropped-flag
  question at once instead of costing a car trip per flag.

  ```
  adb logcat -c && adb shell am force-stop com.i99dev.ilink
  # toggle the service off/on in Settings > Accessibility to force a rebind, then:
  adb logcat -d -s RemoteCtrlA11y | grep "a11y flags"
  ```

  A ROM that preserved everything prints:

  ```
  a11y flags: rom=0x1070 after=0x1070 xmlDeclared=0x1070 droppedByRom=0x0 (ROM preserved all XML flags)
  ```

  `droppedByRom` = `declared AND NOT rom`, i.e. it **names the missing flags directly**.
  Anything other than `0x0` is the finding; record the line verbatim.

  **Decode** (confirmed via `javap -constants` against `android.jar`, not from memory):

  | Bit | Constant | Backs |
  |---|---|---|
  | `0x10` | `FLAG_REPORT_VIEW_IDS` | the **entire** scrape — `findAccessibilityNodeInfosByViewId` |
  | `0x20` | `FLAG_REQUEST_FILTER_KEY_EVENTS` | wheel-voice key interception |
  | `0x40` | `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` | the background window ladder (M2a) |
  | `0x1000` | `FLAG_REQUEST_MULTI_FINGER_GESTURES` | cluster multi-touch dispatch |

  Correct word = `0x1070` = **4208 decimal**. Note `canRetrieveWindowContent` /
  `canPerformGestures` / `canRequestFilterKeyEvents` are **capabilities, not flags** — they
  never appear in this word, so a correct word does *not* on its own prove content
  retrieval is granted.

  **Interpretation.** `droppedByRom=0x0` ⇒ the ROM preserves XML-declared flags ⇒ **both**
  re-asserts (`b2396469`, `840cbb47`) are no-ops and the freeze has another cause; do not
  spend the session on flags. Non-zero ⇒ the dropped-flag hypothesis is live and the
  re-asserts are load-bearing. Either way this single reading settles M2c **and** the
  `flagReportViewIds` question together.

  **Secondary / corroboration only:** `adb shell dumpsys accessibility` while backgrounded,
  recording our whole service block **verbatim** rather than one bit. ⚠️ Unverified — no
  device was available to TASK-022, and several AOSP versions' accessibility service dump
  print label/feedbackType/capabilities/eventTypes/notificationTimeout but **not** the flags
  word. Treat the logcat line as primary.
- **P4 (settles M7/M7c, source-readable — no car needed).** Read
  `nav/transport/SomeIpHudTransport.kt` end to end and answer: does it rebind when the
  binder drops, and does its `ServiceConnection.onServiceConnected` re-issue
  `startSomeIpService` for every id (their `SomeIpHudHelper.java:85-88`)? This was
  deliberately left unread this task to keep the table honest about what was actually
  checked.
- **P5 (settles M8, source-readable).** Read `nav/transport/AmapBroadcastTransport.kt` and
  confirm whether `EXTRA_IS_FOREGROUND` is set to `0` as theirs is
  (`services/HudController.java:161`).

---

## 6. Prior art — the regression any fix must not re-introduce

Project memory records that background keepalive was defaulted OFF on the L5 LR. The
primary sources:

- **`650180b4`** (2026-06-26) *"nav-hud: default background keepalive OFF — it ping-pongs
  single-task maps on-car"*. Body: *"On the L5 LR, 'Keep updating in background' did
  `am start --display <vd>` on Waze, which RELOCATES its single task off the IVI; the VD is
  then torn down and Waze bounces back → the app opens/closes in a loop (conflict the user
  hit). Foreground a11y detection works without it."*
- **`eccf7d67`** *"make foreground-stop display-aware — kills the open/close loop"*.
- **`40c7d339`** *"give up after N VD restarts — BYD re-homes nav app, no loop"*.
- **`b5e4aa2d`** *"make give-up budget monotonic — transient VD success defeated it"*.
- **`77d867d9`** *"never force-stop the nav app on teardown — fixes map disconnect"*.
- **`e9835e25`** / `54827994` (#280, 2026-06-29) removed the mechanism outright:
  *"Removed the background-keepalive VirtualDisplay relocation entirely (option +
  `NavRenderKeepalive` + the a11y pump + budgets): it needs the privileged daemon for
  `am --display`, which can't spawn on UI7 — the relocate then yanked the map through the
  IVI foreground → an ilink↔map ping-pong/freeze. Background-rich now runs purely via
  the notification path + the daemon-free PiP read."* Diff: `NavRenderKeepalive.kt` deleted
  (−287 lines), 140 lines removed from `RemoteControlAccessibilityService.kt`.

This is why `NavRenderKeepalive` does not exist today and why
`readBackgroundNavWindows` (`RemoteControlAccessibilityService.kt:239-255`) is the
*replacement* for it: a passive read of windows that already exist, with no relocation.

**Constraint on any fix that comes out of this document:** it must not reintroduce
`am start --display` on a nav app's task. **All three candidates in §4 can be addressed
without it** — A is a lifetime/ownership change with no display routing at all; B is an
ingest-cadence change; C is a TTL/provider change. If a future proposal does reach for
display relocation, it must state why it will not reproduce the loop, and if it cannot
rule that out it must say so plainly.

A residual comment at `nav/ingest/NavSourceRegistry.kt:66-68` still refers to publishing
the driving app "so the a11y service can keep it rendering on a keepalive VirtualDisplay
(Workstream B, gated)" — that VirtualDisplay was deleted by `e9835e25`. The comment is
stale; `NavActiveApp` itself is still set at `:68`. Flagged, not changed (no production
code this task).

---

## 7. Implementation plan — sequenced, and gated on P1

**Nothing here is authorised to be built by this task.** This is the plan the table
supports, in the order the table supports it.

### Step 0 — run P1 and P4/P5 (P4/P5 need no car)

P1 costs one drive and eliminates two of three candidates. P4/P5 are pure source reads
that close two UNKNOWN rows. **Do not build anything before P1 reports.**

### Step 1 — if P1 says Candidate A: move the pipeline off the Activity

The change is an ownership change, not a new mechanism, and it mirrors M4 rather than M1:

- Make the nav pipeline object graph process-scoped rather than a field of
  `NavHudPlatformPlugin` — i.e. `HudController` + transports + `NavSourceRegistry` become a
  singleton constructed from `applicationContext` (which the plugin is already handed,
  `PlatformPlugins.kt:88`), with the plugin holding a *reference* rather than ownership.
- `NavHudPlatformPlugin.dispose()` (`NavHudPlatformPlugin.kt:306-311`) then tears down only
  the `MethodChannel` and its worker — **not** `registry.stop()` / `controller.dispose()`.
  Disarming becomes exclusively a user action (the `disarm` channel call, `:172-181`) and
  the persisted `NavHudOptions.hudEnabled` flag stays the single source of truth for
  "should the HUD be running", exactly as the auto-arm path already treats it (`:144-146`).
- This is the "one choke point" shape the project already prefers, and it removes a
  lifetime coupling rather than adding a component.

Explicit non-goal: **do not add a nav foreground service.** M1d and M1 together show it
would be cargo-culting a casting anchor while we already over-satisfy the process-priority
requirement.

### Step 2 — if P1 says Candidate B: widen the background read

Cheapest correct change, in their shape (M2a): call the all-displays ladder from
`onAccessibilityEvent` as a fallback when `rootInActiveWindow` yields nothing usable,
instead of only from the 600 ms poll. Their `getRootNodeForPackages`
(`BydAccessibilityService.java:95-144`) is the exact reference. No display relocation, so
§6's constraint is satisfied by construction.

### Step 3 — if P1 says Candidate C: widen the maneuver window

The arrow's freshness is bounded by the `NavManeuverBus` TTL passed per app
(`NavHudPlatformPlugin.kt:113-115,122,130`), and by the arbiter TTL. If distance keeps
moving while the arrow does not, the fix is in that provider, not in the transport or the
service lifetime. Their equivalent has no such split: the maneuver travels inside the same
`c70` payload the keepalive re-fires (`SomeIpHudHelper.java:140-151`).

### Step 4 — only if P3 shows the flag is dropped

Mirror M2c: add `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` to the existing OR in
`RemoteControlAccessibilityService.kt:142-144`. One line, defensive, harmless if the ROM
never drops it — but it should be justified by P3 rather than by symmetry with their code.

✅ **DONE — and widened.** `b2396469` added `FLAG_RETRIEVE_INTERACTIVE_WINDOWS`;
`840cbb47` (TASK-022) added `FLAG_REPORT_VIEW_IDS` for symmetry. Both remain
**defensive and unverified** — the caveat above still stands, and P3 is still what would
justify them. The reason both landed *ahead* of P3 rather than after it: under the
dropped-flag hypothesis, a missing `0x10` and a missing `0x40` produce the **same**
frozen-then-blank cluster, so shipping only one risks a car session concluding
"Candidate B was wrong" when it was right and half-fixed. P3 (now rewritten to read the
whole word) tells us whether either mattered.

### Step 5 — separately, and independent of all of the above

Consider the keepalive cadence (M6, 1 s vs their 200 ms). This is **not** a background bug
by itself — the cadence is identical foreground and background, and the arrow works in
foreground — so it should not be bundled into whichever fix Step 1-3 selects.

---

## 8. Honest status

Everything in this document is source analysis. **No car was available.** Nothing here is
verified on hardware, and every candidate in §4, every probe in §5 and every step in §7
remains **pending on-car verification**. The mechanism inventory in §2 is verified against
the decompile; the comparison in §3 is verified against both trees; the *causal* claim in
§4 is deliberately left as three candidates plus a discriminator, because the source does
not choose between them.
