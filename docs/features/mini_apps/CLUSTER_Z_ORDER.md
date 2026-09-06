# Cluster z-order — three approaches

The XDJA composer on Leopard 8 DOES forward our `ClusterActivity`
frames to the cluster MCU (verified 2026-05-02). The remaining
problem is z-fighting against `com.example.amapservice` — the ADAS
map, which runs as `sharedUserId="android.uid.system"` and claims
the cluster display first via `ContentProjectionManager`.

The reference docs at `byd/l8/dlink-unit/Gauge Cluster/` enumerate
three ways to win z-order on the cluster face. From cheapest to
most invasive:

## 1. Window flags + activity isolation (no extra perms)

What we ship today:

- `launchMode="singleInstance"` — every cluster surface lives in
  its own task. amap can't push us off the stack.
- `FLAG_SHOW_WHEN_LOCKED | FLAG_TURN_SCREEN_ON | FLAG_KEEP_SCREEN_ON
  | FLAG_FULLSCREEN | FLAG_LAYOUT_NO_LIMITS` — denies the system
  any reason to demote our window, denies amap any way to dim our
  view via system bar overlays.
- `WebView.setZOrderOnTop(true)` — within our window, the
  WebView's underlying SurfaceView climbs above sibling
  SurfaceViews.
- `am start-activity --activity-reorder-to-front` — bubbles our
  task to the top of the display's task stack on every launch.

This works **most of the time**. The known limitation: when amap
re-projects (e.g. user starts a new navigation) it can briefly take
back the slot. We re-pop next time the user re-opens the mini-app.

## 2. Activity replacement via priority-100 intent-filter

If approach 1 isn't enough, the documented Phase B follow-up is to
register `ClusterActivity` with `priority=100` against the slot-host
actions amap declares:

```xml
<activity android:name=".display.ClusterActivity" ...>
  <intent-filter android:priority="100">
    <action android:name="com.byd.cluster.projectionmanager.service.startBottomEmptyActivity"/>
    <category android:name="android.intent.category.DEFAULT"/>
  </intent-filter>
  <intent-filter android:priority="100">
    <action android:name="com.byd.cluster.projectionmanager.service.startTopEmptyActivity"/>
    <category android:name="android.intent.category.DEFAULT"/>
  </intent-filter>
  <!-- + the four `com.byd.cluster.START_CLUSTER_VIEW_*` actions
       (FANGCHENGBAO, OCEAN, DYNASTY, DENZA) — see
       `byd/l8/dlink-unit/Gauge Cluster/reference/projection-contract.md` -->
</activity>
```

PackageManager picks the highest-priority match; with BYD's filter
at priority 0, our resolution wins. **Caveat:** amap is
`persistent="true"`, which biases some IntentResolver paths — if
`priority=100` doesn't beat persistence, fall back to `cmd package
set-default-activity` from a privileged setup script.

When we ship this, we ALSO need a settings UI for "which mini-app
should fill the cluster slot" — when the slot fires without a
`bundleUri` extra, the activity reads from SharedPreferences and
mounts the user's chosen mini-app's bundle. Without that, hijacking
the slot leaves the cluster blank when amap thought it could
project there.

## 3. ContentProjectionManager AIDL (the supported BYD path)

The proper supported way:

```kotlin
IntelligenceApiManager.init(applicationContext)
val mgr = IntelligenceApiManager.getContentProjectionManager()
mgr.registerContentProjectionCallback(callback)
mgr.startContentProjection(ScreenPosition.CLUSTER_FULL, ContentType.MAP_VIEW)
```

Requires:

- The BYD AIDLs from `byd/l8/dlink-unit/Gauge Cluster/aidl/`
- `BYDAUTO_INSTRUMENT_COMMON` + `BYDAUTO_INSTRUMENT_GET` system
  permissions (signature-protected — granted only to system-signed
  apps OR via `pm grant` from privileged shell)
- A `ContentProjectionCallback` implementation in the host

This is the cleanest behaviour-wise (we cooperatively switch with
amap rather than hijacking) but the heaviest engineering lift.
Phase C territory.

## Decision tree

- Want to overlay something light on the cluster, accept that amap
  may briefly win sometimes? → Approach 1 (current).
- Want to fully own the cluster face for a chosen mini-app, willing
  to ship a settings flow + manifest-pinned filters? → Approach 2.
- Want to play nicely with the cluster service, willing to bring
  in BYD's SDK + privileged perms? → Approach 3.

## Why we're not on Approach 2 or 3 today

Both require the host APK to ship features that benefit from being
gated behind a "cluster-as-default-canvas" UX decision the user
hasn't made yet. Until there's a clear product call about whether
ilink should own the cluster face by default, we ship Approach 1
(low-risk, mini-apps opt in per-launch via `surface.create`) and
keep this doc as the bridge to 2 + 3 when that call comes.
