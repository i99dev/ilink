# 2. DiLink 5.0 — Car detection

How the runtime knows it is on a Di5.0 / Leopard 5 so the planner
picks the DiShare/cluster transports. **Verified correct on-car
2026-05-18** — detection was never the bug.

## The chain

```
Kotlin BydCarInfoBinder.snapshot()
  → Dart ModelDetector._classify / _resolveModel  (model_detector.dart)
  → variantId "l5"
  → MiniAppDispatcher.setModelIds(["l5","di5.0"])
  → CarProfileRegistry.setActive("l5")  →  LEOPARD5_PROFILE
  → DisplayLaunchPlanner reads profile.capabilities.passenger
```

## Tier-1 framework fails, Tier-2 sysprop wins (this is normal)

`BydCarInfoBinder` (Kotlin) has two tiers:

1. **Framework reflection** into `com.byd.car.ICarInfoManager` — on a
   user/privileged install this throws `ClassNotFoundException` (the
   BYD framework jar is not on the app classloader). Expected.
2. **Sysprop fallback** — reads `persist.sys.model_variant.model`
   (uppercased → `carType`) and `persist.sys.vehicle_40d_code`
   (→ `vehicleId`). Same values the framework would return.

Live L5 boot log (authoritative):

```
I BydCarInfo: framework path unavailable: ClassNotFoundException
I BydCarInfo: snapshot via sysprops: carType=FCBSF vehicleId=153
I MiniAppDispatcher: modelIds: [unknown] -> [l5, di5.0]
```

## The discriminators on this L5

| sysprop | value | meaning |
|---|---|---|
| `persist.sys.vehicle_40d_code` | `153` | L5 (vs L8 = 155) |
| `persist.sys.model_variant.model` | `fcbsf` | FangChengBao FCBSF badge (L5; L8 = `fcbsq`) |
| `persist.sys.car.type` | `153` | mirror |
| `ro.product.device` / `ro.build.fingerprint` | `DiLink5.0` / `BYD-AUTO/DiLink5.0/DiLink5.0:12/SKQ1.230128.001/…` | Android 12, SDK 32 |

`model_detector.dart:_resolveModel` rule: `carType=="FCBSF" &&
vehicleId==153  →  ("l5","Leopard 5")`.

## The Dart→Kotlin wiring (was an audit-D1 bug, now fixed)

`ModelDetector.detect()` pushes `["l5","di5.0"]` to Kotlin via the
`ilink/model_detector` channel → `MiniAppDispatcher.setModelIds()`.
That method also calls **`CarProfileRegistry.setActive(sanitized
.firstOrNull())`** so `forActiveCar()` / `forVariant("l5")` returns
`LEOPARD5_PROFILE`. (Historically `setActive()` had zero callers and
`forActiveCar()` was permanently `GENERIC_PROFILE`; fixed under audit
D1. Confirmed working on-car: the DiShare path only runs because the
profile resolves to L5.)

## `LEOPARD5_PROFILE` — the bits that matter for displays

`android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/definitions/Leopard5.kt`

| field | value | consumer |
|---|---|---|
| `variantId` | `"l5"` | registry key |
| `dilinkFamily` | `Di50` | — |
| `capabilities.passenger` | **`DishareQuickShare`** | `DisplayLaunchPlanner` — the entire Di5.0↔Di5.1 fork is this one enum |
| `capabilities.cluster` | `{DishareQuickShare, Icons}` | cluster tag eligibility in `DeviceTagResolver` |
| `displays.secondaryDisplayOwners` | `{"com.byd.containerservice":"passenger"}` | classifier role for 2/3/4 |
| `displays.overrideLabels` | `{2:"FSE Co-pilot",3:"Small Panel",4:"Driver Dashboard"}` | picker labels |

> A prior debugging detour set `cluster = {Icons}` (cluster
> "unsupported"). That was **reverted** — the working Shaheen app
> proves cluster *is* reachable (just not via DiShare quickShare). Keep
> `{DishareQuickShare, Icons}`.

## Endpoint identity is volatile

`127.0.0.1:5999` has resolved to L8 / L5 / Song PLUS across sessions.
**Always re-profile** (`adb -s … shell getprop | grep
vehicle_40d_code`) before any device-specific reasoning. Song PLUS is
a normal Di5.0 car but its DiShare APK version has **not** been pulled
— treat its cluster behaviour as the unverified inherited assumption,
not proven.
