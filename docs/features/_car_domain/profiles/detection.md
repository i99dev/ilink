# Trim detection

Detection answers: **"which `variantId` does this car resolve to?"**
The answer drives both the active static trim profile and the
runtime ProfileKey passed to the resolver.

## Signals

The detector binds to BYD's canonical car-identity SDK
(`com.byd.car.ICarInfoManager`) and falls back to BYD-written
system properties when the framework class isn't on the user-app
classloader. Both paths surface the **same canonical pair** the
framework writes at boot.

| Source | Source key | Stability | Used as |
|---|---|---|---|
| **carType** | `ICarInfoManager.getCarType()` (privileged) → uppercase(`persist.sys.model_variant.model`) (fallback) | Very strong — canonical 21-string `VehicleCarType` enum | Primary key — `_resolveModel` switch |
| **vehicleId** | `ICarInfoManager.getVehicleId()` (privileged) → parse(`persist.sys.vehicle_40d_code`) (fallback) | Very strong — BYD's internal trim integer | Sub-trim disambiguation inside FangChengBao (L5=153, L8=155) and standalone match for trims where carType reports `unknown` (Song PLUS = 243) |
| **brand** | `getBrand()` — only on framework path | Strong | Sentry context only — not part of the resolution key |
| **bodyType** | `getVehicleType()` — only on framework path | Strong | Sentry context — CAR / SUV / MPV / TRUCK |
| **vin** | `getSerialNumber()` — only on framework path | Strong | Telemetry / pair handshake — not in the resolution key |
| **dilinkFamily** | `ro.vehicle.type` prefix (`Di5.1_*` / `Di5.0_*`) | Strong | Coarse-level fallback for trims not yet in `_resolveModel` |
| **fingerprint** | `ro.build.fingerprint` | Exact but volatile across OTAs | `ProfileKey.fingerprint` slot for local profile resolution |

## Boot-time flow

```
ModelDetector.detect()                 (lib/platform/device/model_detector.dart)
       │
       ▼
   getCarInfo channel                  (BydCarInfoBinder)
       │
       ├── tier 1: ICarInfoManager via Spi reflection (privileged installs)
       └── tier 2: persist.sys.model_variant.model + persist.sys.vehicle_40d_code
       │
       ▼
   _resolveModel(carType, vehicleId)   (switch — first match wins)
       │
       ├── (FCBSQ, 155)  → ('l8',        'Leopard 8')
       ├── (FCBSF, 153)  → ('l5',        'Leopard 5')
       ├── vehicleId 243 → ('song_plus', 'Song PLUS')   (carType-less)
       ├── carType=HAN   → ('han',       'BYD Han')
       ├── carType=TANG  → ('tang',      'BYD Tang')
       ├── …             → …                            (21 total)
       └── miss          → variantId = null (Generic fallback)
       │
       ▼
ProfileKey(dilinkFamily, variantId, subTrim, fingerprint)
       │
       ├──→ CarProfileRegistry.setActive(variantId)   (static trim profile)
       └──→ resolve(ProfileKey)                       (runtime profile)
```

## Why `(carType, vehicleId)` is the key

These are the two signals **BYD's own framework writes** at boot
and that **BYD's own apps consume** (BootGuide, SoftwareActivation,
UserTutorial all import `com.byd.car.VehicleCarType`). Using them
means:

- Adding a new BYD model is a one-row entry in `_resolveModel`,
  not a heuristic spelunk.
- ROM-cosmetic strings (outsw / system.model / vendor.device) are
  no longer in the resolution path, so a future ROM that
  re-formats them can't break detection.
- The framework path and sysprop path can't drift because the
  same framework writes both the binder and the props.

## When the integer alone is enough

A few models have `persist.sys.model_variant.model = "unknown"`
(Song PLUS does this — single-trim model, BYD doesn't bother
populating the token). For those, the integer
(`persist.sys.vehicle_40d_code`) is sufficient on its own —
the resolver has a `vehicleId`-only branch that catches
`243 → song_plus` without needing a carType.

## When we have richer evidence (framework path)

System-signed installs reach the privileged framework path and
get the richer snapshot: brand (DYNASTY / OCEAN / DENZA / F / R),
body type (CAR / SUV / MPV / TRUCK), VIN, powertrain code, driver
seat. These don't change the resolved `variantId` — they go to
Sentry as scope tags and to `CarProfile` consumers that benefit
from the extra context.

## Sub-trim resolution

Sub-trim (Flagship / Navigator / Ultra / etc.) is resolved
separately by `SubTrim.fromHardwareSignals(...)` and feeds the
`ProfileKey.subTrim` slot. The detection key is **DiLink generation
× hardware sub-trim × fingerprint** — not `variantId` alone — per
[memory: detection key is DiLink generation × hardware sub-trim].

Example: a single "L5" badge spans Flagship / Navigator / Ultra.
The active static trim profile only differs across (`l5`, `l5l`,
`l5u`); within each, the runtime profile's ProfileKey carries
the `subTrim` slot for local profile precision.

## Probe evidence

Every entry in a `definitions/*.kt` file has a comment block citing
the on-car probe JSON it was built from, e.g.:

```kotlin
/**
 * Sources:
 *   * Live collector probe: byd-fingerprint-34.1.17-20260506-074202.json
 *     (build `2511242.1` / 2025-12-07, schemaVersion 0.8.0).
 *   * `vehicle40dCode` = "155" (BYD internal code for L8).
 *   * `modelVariant` = "fcbsq" (last letter discriminates trim).
 */
```

The collector app produces these JSONs. They're the empirical
ground truth. **Never** invent a profile field without a probe to
back it; mark uncertain fields with TODO comments and run an
on-car test before promoting.

See [`../features/_car_domain/profiles/adding-a-trim-variant.md`](adding-a-trim-variant.md) for the
historical log.

## Active-car cache

After `ModelDetector.detect()` resolves, `ModelDetectorChannel`
calls:

```kotlin
CarProfileRegistry.setActive(variantId)
```

That populates the `AtomicReference<CarProfile>` so every
subsequent `CarProfileRegistry.forActiveCar()` read is lock-free.
Subsequent calls to `setActive(...)` overwrite — for example, a
profile-override path triggered by Settings.

`forActiveCar()` is the hot path. Plugins on every cold boot
(`CapabilityRegistry.staticSeed`, `DisplayPlatformPlugin`,
`PackagePlatformPlugin`, …) read through it.
