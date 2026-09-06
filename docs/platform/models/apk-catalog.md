# BYD system-app catalog

What's in `/system/app` and `/system/priv-app` on a real BYD head
unit, and which packages matter for our compatibility work.
Sourced from the 5f Di5.0 extraction (91 BYD APKs total in
`/system/app`); L5L Di5.1 layout overlaps heavily — verify per
trim by re-running the catalog tool.

## Packages relevant to MiniApp Gate

These are the ones we actively interact with or actively avoid:

| APK | Package | Role | What we care about |
|---|---|---|---|
| `BydAutoMap.apk` | **`com.byd.naviauto`** | BYD's own ADAS map (NAVI + cluster meter) | The cluster-slot squatter on non-Huawei trims. Eviction target for `surface.amap_force_stop` on `l5l` / `di5.1`. |
| `BydLaunchermap.apk` | **`com.byd.launchermap`** | Launcher with map integration | Owns `com.byd.automap.service.VirtualDisplayService` — handles the cluster's virtual display. Probably the actual launcher on screens that don't have a vendor-replaced launcher. |
| `BydGesture.apk` | **`com.byd.gesture.global`** | BYD's gesture handler | Has `com.byd.gesture.global.InputEventService`. Different mechanism from our AccessibilityService — unlikely to conflict with `gesture.input_tap` / `gesture.input_swipe`. |
| `BydAutoVoice.apk` + Engine + TTS | `com.byd.*` | BYD's voice assistant stack | Runs in parallel with our voice path; we use OpenAI Realtime (see project memory `project_llm_providers`), they use BYD's STT+TTS. |
| `BydDriveMode.apk` | `com.byd.*` | Driving-mode controller (ECO / Sport / Snow) | Out of scope today; potential `car.drive_mode` family later. |
| `BydDms.apk` | `com.byd.*` | Driver-monitor system (camera-based) | Out of scope; safety-critical, OEM-only. |
| `BydCarAudioAOSP.apk` | `com.byd.*` | Car-audio routing | Routes `just_audio_background` through it; no direct interaction. |
| `BydDiLinkAccountService.apk` | `com.byd.*` | BYD's account / OEM cloud | OEM application; ilink itself has no account service. |

## Deep dive — `com.byd.naviauto` (BydAutoMap.apk)

The single most important non-Huawei BYD app for cluster-related
work. From the 5f firmware's manifest (45 activities, 19 services,
7 providers, 12 receivers):

```xml
<activity
    android:name="com.byd.automap.central.CentralActivity"
    android:taskAffinity="com.byd.naviauto"
    android:launchMode="2"  <!-- singleTask -->
    android:exported="true">
  <intent-filter>
    <action android:name="android.intent.action.MAIN"/>
    <category android:name="android.intent.category.HOME"/>
    <category android:name="android.intent.category.HOME_ONLY"/>
    <category android:name="android.intent.category.LAUNCHER"/>
  </intent-filter>
</activity>

<activity
    android:name="com.byd.automap.meter.MeterActivity"
    android:taskAffinity="com.byd.naviauto.meter"
    android:launchMode="3"  <!-- singleInstance — KEY -->
    android:allowEmbedded="true"
    android:exported="true">
  <category android:name="android.intent.category.DEFAULT"/>
  <!-- No <intent-filter> with action; invoked by explicit -n -->
</activity>

<activity
    android:name="com.byd.automap.meter.MeterTbtActivity"
    android:taskAffinity="com.byd.naviauto.metertbt"
    android:launchMode="3"
    .../>
```

Two facts drive our eviction strategy:

1. **`MeterActivity` is `singleInstance`** — it claims the
   secondary display's task stack and won't let go until the
   process is killed. `am stack move-task` on top of it does
   nothing.
2. **No intent filter** — we can't trigger it via implicit
   actions. It's invoked explicitly by `com.byd.naviauto`'s own
   internal launcher when navigation kicks in.

So the eviction is `am force-stop com.byd.naviauto`. That kills
the whole package, releases the singleInstance MeterActivity,
freeing the cluster's task stack for our ClusterActivity.

## Notable absences on 5f Di5.0

These are NOT in the 5f catalog (we checked); they appear on
Di5.1 trims:

- `com.example.amapservice` — Huawei's ADAS map. L8-only.
- `com.huawei.*` — Huawei integrations. L8-only.

Confirms the per-model `surface.amap_force_stop` divergence: on
L8 we target Huawei's package, on every other trim we target
BYD's own.

## Out of scope (large but irrelevant)

The 5f catalog includes some APKs we deliberately ignore:

| APK | Why we don't care |
|---|---|
| `AutoVideo.apk` (456 MB) | Pre-installed video viewer. No SDK surface. |
| `BydDroneClient.apk` (83 MB) | Drone-pairing UI. Niche. |
| `AromeExt.apk` (28 MB) | Fragrance system extension. We don't write to fragrance from mini-apps. |
| `BydCDR.apk` | Crash data recorder. OEM-only. |
| `BydEtc.apk` | ETC (toll) integration. Region-specific. |
| `BydHealthDiagnostic.apk` | Vehicle self-diagnostic. Out of scope. |
| `BydIceBox.apk` (59 MB) | Refrigerator on Tang/Yuan trims. Not on F-series. |
| `BydIOTOTA.apk` | OEM OTA client. Independent. |

## Re-running the catalog on a new firmware

```sh
# After firmware-extraction.md gets you a system.img:
python tools/ext4_catalog.py \
  D:/byd/extracted/<trim>/parts/system.img \
  D:/byd/extracted/<trim>/system.catalog.txt

# Find every BYD APK:
grep -iE "Byd[A-Z][a-z]+\.apk$" D:/byd/extracted/<trim>/system.catalog.txt

# Compare against the 5f catalog to spot trim-specific additions/removals:
diff <(grep "/system/app/Byd" D:/byd/extracted/5f/system.catalog.txt | awk '{print $NF}' | sort) \
     <(grep "/system/app/Byd" D:/byd/extracted/<trim>/system.catalog.txt | awk '{print $NF}' | sort)
```

A new package that only appears on the new trim is a candidate for
ADAS-map override (if it's a map-related package) or for a new
family altogether.
