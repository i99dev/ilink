# OpenBYD 2.3.2 → ilink: P3 / P5 logic extraction

Decompiled OpenBYD 2.3.2 (`com.sr.openbyd`, jadx incl. `--show-bad-code`). This is a
**logic/requirements** reference — no obfuscated code is copied; values cited are the
*car-tested constants* OpenBYD ships. Use it to implement P3/P5 in our architecture
later. Nothing here is wired yet.

Source of truth files: `services/MapNotificationListenerService.java` (notification
parser), `services/YandexManager.java`, `services/GoogleMapsManager.java`,
`proxy/CarControlImpl.java` (HAL setters).

> **STATUS: P3 + P5 implemented** on `feat/nav-hud-lang-and-background` (degrade-safe,
> gated). P5 → `NavTextParse.cleanNextStep` + `A11yNavSource` nextStep view-id. P3 →
> `NavAlertExtractor` (reuses `NavManeuverExtractor.resourceEntryNames`) +
> `NavNotifListenerService` (Yandex-only, `cameraAlerts`-gated) +
> `InstrumentHalWriter.writeFrame`/daemon/`HalCanFidTransport` camera+safety. Renders
> on CAN-FID (7.0UI/Huawei); SOME/IP shows no alerts (same as OpenBYD). Pending on-car:
> glyph confirmation + traffic-light countdown seconds. The recipes below remain as the
> design record.

---

## P3 — Yandex safety / hazard / camera / traffic-light alerts

### 1. Logic summary
Yandex Maps does **not** put alerts in notification *text*. OpenBYD reads the
ongoing Yandex notification's **RemoteViews**, finds the `ImageView`s, resolves each
one's **drawable resource-entry-name** in Yandex's package, and pattern-matches that
name (`road_alerts_camera_32`, `traffic_light_*`, …) to a BYD alert code. The same
RemoteViews scan also yields the maneuver icon name (→ turn code) and the title
carries the distance. Everything is packed into one guidance frame and pushed to the
cluster via the **native BYD HAL alert setters** (`sendCameraGuidanceInfo` /
`sendSafeGuidanceInfo`), which are a *separate channel from SOME/IP RoadInfo*.

### 2. Inputs
- Ongoing `StatusBarNotification` from `ru.yandex.yandexmaps` (FLAG_ONGOING).
- `extras["android.title"]` → distance string (e.g. "450 m"); `["android.text"]` → road.
- `notification.bigContentView / contentView / headsUpContentView` **plus** the
  reflection-recovered `createBigContentView()/createContentView()/createHeadsUpContentView()`
  RemoteViews (helper `lp1` walks the RemoteViews actions for `ImageView` resource ids
  + tags `primaryIconTinted`/`primaryIcon`, returns the **resource entry name**).
- Each ImageView's resource entry name resolved via
  `pkgResources.getResourceEntryName(resId)`.

### 3. Logic (step by step)
1. Gate: title contains a digit (a real maneuver) AND text non-blank, else ignore.
2. Scan RemoteViews → maneuver icon resource name → `YandexManager.getTurnIconFromManeuverText(name)` → TURN_ICON code (default 11/straight).
3. Scan RemoteViews ImageViews again; for each resolved resource entry name, classify:

   | resource entry name        | channel | type | dist | state |
   |----------------------------|---------|------|------|-------|
   | `road_alerts_camera_32`    | camera  | 1    | 100  | 2     |
   | `road_alerts_other_32`     | safety  | 1    | 100  | 2     |
   | `road_alerts_accident_32`  | safety  | 10   | 100  | 2     |
   | `road_alerts_road_works_32`| safety  | 11   | 100  | 2     |

   (`dist=100`, `state=2` are **fixed placeholders** — Yandex gives no distance; "2" = active. These are the values OpenBYD actually sends and renders on the cluster.)
4. Traffic light: ImageView named `traffic_light_data`/`traffic_light_expanded` whose
   icon resource name contains `red`/`green`/`yellow` → `trafficLightColor`; the
   `traffic_light_data` text → `trafficLightSeconds` ("0" → null = cleared).
5. Build a frame: `(maneuverIcon, distance, road, camera{t,d,s}, safety{t,d,s}, light{color,sec})`.
6. Push; the cluster shows the camera/safety glyph + traffic-light countdown.

### 4. Output (which fields / transport)
- Camera → BYD HAL `BYDAutoInstrumentDevice.sendCameraGuidanceInfo(type, dist, state)` (CarControlImpl.java:1274).
- Safety → `sendSafeGuidanceInfo(type, dist, state)` (CarControlImpl.java:1484).
- Traffic light → carried in the SOME/IP / amap frame OpenBYD builds (`r60.m/n`).
- Our `NavGuidance` **already has** these exact fields: `cameraType/cameraDistance/cameraState`, `safetyType/safetyDistance/safetyState`, `trafficLightColor/trafficLightSeconds`.

### 5. Edge cases
- `getResourcesForApplication(pkg)` may throw → null → no alert (frame still has maneuver).
- Reflection-recovered RemoteViews wrapped in try/catch; any failure → skip that view.
- Staleness: `checkExpirationRunnable` polls active notifications every 1 s; if no
  Yandex notif with a digit-title + non-blank text for >30 s (a11y >10 s) → clear nav.
- A blank/"0" traffic-light second clears the countdown.

### 6. Our-codebase mapping (recipe — DO NOT implement yet)
```
Producer (Yandex notif → alert fields):
- File: android/.../nav/logic/NavNotifParse.kt  (or a new NavNotifIconScan.kt)
- Add: a RemoteViews ImageView → resource-entry-name scanner (reflection), because
  our NavNotifParse is TEXT-only today and can't see Yandex's icon-encoded alerts.
- Map names → codes using the verified table above. Reuse the dead
  logic/WazeAlertClassifier.kt + BydAlertCodes.kt as the kind→code home, but REPLACE
  its provisional numbers with the verified ones (camera 1; safety other 1 / accident
  10 / road_works 11; dist 100; state 2).
- Set cameraType/.../safetyType/... + trafficLightColor/Seconds on the emitted
  NavGuidance (model already supports them).
- Entry point: ingest/NotifNavSource.kt (it already handles the notification path);
  needs the Notification object, not just extras — thread it through.

Transport (make it render):
- Our active 5.0UI path is SOME/IP, whose RoadInfo codec carries NO camera/safety —
  exactly like OpenBYD's SOME/IP. OpenBYD renders alerts via the HAL setters. So add a
  camera/safety write on the CAN-FID/daemon path:
  - transport/canfid/BydGuidance.kt: add sendCameraGuidanceInfo(type,dist,state) +
    sendSafeGuidanceInfo(type,dist,state) (reflect BYDAutoInstrumentDevice's methods,
    same pattern as the existing instrument writes).
  - transport/canfid/InstrumentHalWriter.kt: call them in writeFrame when the frame
    carries camera/safety.
  - helper/DashDaemon.java doHalGuide + transport/HalCanFidTransport.push: add the
    camera/safety/light fields to the halGuide JSON.
- 5.0UI SOME/IP cars: alerts need the HAL path too (SOME/IP can't carry them). Decide
  on-car whether to also run a HAL alert write alongside SOME/IP, or accept alerts as
  CAN-FID-only (7.0UI/Huawei) for v1.
- Flag: gate behind NavHudOptions.cameraAlerts (already exists, default ON).
```

### 7. Code skeleton (our style — guidance only)
```kotlin
// nav/logic/NavNotifIconScan.kt — new, pure-ish (reflection lives here)
object NavNotifIconScan {
    /** ImageView resource-entry-names found in a notification's RemoteViews. */
    fun iconNames(ctx: Context, n: Notification, pkg: String): List<String> { /* lp1-equivalent scan */ }
}

// nav/logic/WazeAlertClassifier.kt / BydAlertCodes.kt — replace provisional numbers
//   camera: 1 ; safety: other=1, accident=10, road_works=11 ; dist=100 ; state=2

// ingest/NotifNavSource.kt — when pkg is Yandex, scan icon names, classify, and set
//   cameraType/.../safetyType/...; pass trafficLight color/seconds through.

// transport/canfid/BydGuidance.kt
fun sendCameraGuidanceInfo(w: FidWriter, type: Int, dist: Int, state: Int) { /* HAL reflect */ }
fun sendSafeGuidanceInfo(w: FidWriter, type: Int, dist: Int, state: Int)   { /* HAL reflect */ }
```

### 8. On-car test cases
- Yandex nav passing a fixed speed camera → cluster shows camera glyph.
- Pass an accident / road-works Yandex alert → cluster safety glyph (type 10 / 11).
- Approach a traffic light (Yandex assistant) → cluster shows color + countdown, clears at 0.
- Confirm the maneuver icon + distance still render alongside the alert.
- Toggle `cameraAlerts` off → no alert glyph, maneuver unaffected.
- 5.0UI (SOME/IP) car: confirm whether alerts render at all (decides HAL-alongside-SOME/IP).

---

## P5 — Google Maps secondary "then…" road

### 1. Logic summary
Google Maps exposes a *next-step* string like "then turn right onto Elm St".
OpenBYD strips the leading maneuver phrase with an ordered list of 24 regexes,
leaving just the road name ("Elm St"), and uses it as the **secondary road**.

### 2. Inputs
- A Google Maps a11y *next-step* text node (read in OpenBYD's `BydAccessibilityService.handleGoogleMapsEvent`; passed as the 6th arg `str5` to `GoogleMapsManager.updateNavigationTexts(ctx, dist, road, remDist, remTime, nextStep)`).
- (Alternative source: the notification `bigText`/`subText`, which also carries "then …".)

### 3. Logic (step by step)
1. `trim()` the next-step string.
2. Try the 24 prefix regexes **in order** (all `(?i)^…`); first match → `replaceAll("")`.
   Order (longest/most-specific first):
   `^then turn right onto`, `^then turn left onto`, `^then merge onto`,
   `^then take the ramp onto`, `^then keep right onto`, `^then keep left onto`,
   `^then take the exit onto`, `^then turn sharp right onto`, `^then turn sharp left onto`,
   `^then turn slight right onto`, `^then turn slight left onto`,
   `^then turn right`, `^then turn left`, `^then merge`, `^then keep right`,
   `^then keep left`, `^then`, then the no-"then" variants
   `^turn right onto`, `^turn left onto`, `^merge onto`, `^take the ramp onto`,
   `^keep right onto`, `^keep left onto`, `^take the exit onto`.
3. `trim()` the remainder → the secondary road name.

### 4. Output
- `secondaryRoadName` on the frame. We already serialize it: `AmapBroadcastTransport`
  emits it as `NEXT_NEXT_ROAD_NAME`. (SOME/IP RoadInfo has no secondary-road field,
  same as OpenBYD.)

### 5. Edge cases
- No regex matches → return the trimmed string unchanged.
- Empty/blank → empty secondary (omit the Amap extra).

### 6. Our-codebase mapping (recipe — DO NOT implement yet)
```
- File: android/.../nav/logic/NavTextParse.kt — add cleanNextStep(s): String (the 24
  ordered regexes, compiled once). Pure + host-testable.
- File: ingest/A11yNavSource.kt + NavAppA11y.GOOGLE_MAPS — add an optional nextStep
  view-id; when present, read it, run NavTextParse.cleanNextStep, set
  secondaryRoadName on the emitted NavGuidance.
  (Exact Google Maps view-id wasn't in the decompile — confirm on-car via a node
  dump; OR derive secondary from the notification bigText in NavNotifParse instead.)
- No transport change: AmapBroadcastTransport already sends NEXT_NEXT_ROAD_NAME.
```

### 7. Code skeleton (our style — guidance only)
```kotlin
// nav/logic/NavTextParse.kt
private val NEXT_STEP_PREFIXES: List<Regex> = listOf(/* 24 ordered (?i)^… */).map { Regex(it) }
fun cleanNextStep(s: String): String {
    val t = s.trim()
    for (re in NEXT_STEP_PREFIXES) if (re.containsMatchIn(t)) return re.replaceFirst(t, "").trim()
    return t
}
```

### 8. On-car test cases
- GMaps showing "then turn right onto King Fahd Rd" → secondary = "King Fahd Rd" on cluster widget.
- "then merge" (no road) → secondary empty, no stale value.
- Arabic next-step → transliterated by the existing controller choke (no double-fold).

---

## Per-app alert coverage (verified across all 3 handlers)

Checked `BydAccessibilityService.handle{GoogleMaps,Waze,Yandex}Event` + the notification
parser. **Alerts are Yandex-only** — Google Maps and Waze have NO camera/safety/speed
extraction in OpenBYD, so there is nothing to miss there.

| App | a11y view-ids OpenBYD reads | Alerts? | Our status |
|-----|------------------------------|---------|------------|
| Google Maps | `distance_text`, `top_cue_text`, `bottom_cue_text`, `step_instruction_container`, `navigation_time_remaining_label`, `next_step_instruction_container` | **none** | parity except **P5** secondary road (`next_step_instruction_container`); minor: `bottom_cue_text` appended to road with " - " |
| Waze | `navBarDistance`, `navBarStreetLine`, `lblArrivalTime`, `lblTimeToDestination`, `lblDistanceToDestination`, `navBarDirection`, `laneGuidanceView` | **none** | **full parity** (arrow + P2 lanes + texts; `lblArrivalTime` unused by OpenBYD too) |
| Yandex | `text_maneuverballoon_distance`, `text_maneuverballoon_metrics`, `text_nextstreet`, `textview_eta_distance`, `textview_eta_time`, `image_maneuverballoon_maneuver`, `exit_number_text` | **camera/safety/traffic-light** via notification ICONS (P3) | P3 missing; minor: `exit_number_text` (exit number) not read |

**P5 exact view-id (now confirmed):** Google Maps `:id/next_step_instruction_container`,
read as **contentDescription**, → `cleanNextStep` → secondary road. (Updates the P5
recipe above, which had the view-id as "confirm on-car".)

Minor optional extras (not in our scope, tiny): GMaps `bottom_cue_text` (extra road
context), Yandex `exit_number_text` (motorway exit number).

## Other notes from the sweep (not new gaps)
- `RoadNameCache` (1 s blank-retention) — already ported (P4, shipped).
- Lane guidance — already scaffolded (P2, shipped); classification reuses the arrow registry exactly as OpenBYD does.
- `sendSecondaryGuidanceInfo` (next-next maneuver icon, FID 1139834896 / dist 1139834904) exists in OpenBYD but `r60.secondaryIconId` is hardcoded `-1` in 2.3.2 → inert there too; skip.
- Maneuver/amap icon tables, transliteration, SOME/IP RoadInfo, arrow capture, Amap broadcast, notification breadth — all already parity/ahead.
