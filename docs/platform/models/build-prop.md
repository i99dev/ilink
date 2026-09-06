# `build.prop` reference per model

System-property values that distinguish each BYD trim, sourced from
real firmware extraction. Used by `ModelDetector._classify` to map
a head unit to a `model_match` string at boot.

## Authoritative columns

The `ModelDetector` reads these eight props via the
`ilink/model_detector` platform channel and classifies by the
first three. The remaining are passed through to Sentry for
diagnostic context (see `sentry_context_sync.dart`).

| Prop | Use | L8 (Di5.1) | L5L (Di5.1) | 5f (Di5.0) |
|---|---|---|---|---|
| `ro.product.vendor.device` | DiLink family detection | `DiLink5.1` (assumed; encrypted OTA) | `DiLink5.1` (assumed) | **`DiLink5.0`** |
| `ro.vehicle.type` | DiLink family fallback | `Di5.1_5.0UI` (assumed) | `Di5.1_5.0UI` (assumed) | **`Di5.0_5.0UI`** |
| `ro.vehicle.type.value` | trim discriminator integer | unknown — TBD on hardware | unknown — TBD on hardware | **`19`** |
| `ro.byd.ui.splitscreen` | multi-display capability gate | `1` | `1` | **`0`** |
| `ro.byd.ui.platformized` | newer-platform feature gate | `1` (assumed) | `1` (assumed) | **`0`** |
| `ro.byd.ui.integrate` | UI integration gate | `1` (assumed) | `1` (assumed) | **`0`** |
| `ro.product.system.model` | display label | varies | varies | `qssi system image for arm64` |
| `ro.product.board` | SoC | unknown | unknown | **`SM7325`** (Snapdragon 7c+ Gen 2) |

L8 / L5L values marked "assumed / unknown" are inferred from the OTA
metadata (`pre-device=IVI`, `post-build=BYD-AUTO/IVI/IVI:13/...`)
and need on-hardware verification. The 5f values are confirmed from
the extracted `system/build.prop`.

## Classification ladder

```
                    ┌─────────────────────────────────┐
                    │ ro.byd.ui.splitscreen == 1 ?    │
                    └──┬─────────────────────────────┬┘
                       │ no                          │ yes
                       ▼                             ▼
                ┌──────────────┐             ┌──────────────────┐
                │ Di5.0 family │             │ Di5.1 family     │
                │ → "di5.0"    │             │ → "di5.1"        │
                └──────┬───────┘             └────────┬─────────┘
                       │                              │
                vehicle.type.value == 19?      product.system.model
                       │                       contains "l8" or "l5l"?
              ┌────────┴────────┐           ┌──────────┴─────────┐
              │ yes             │ no        │ yes              │ no
              ▼                 ▼           ▼                  ▼
        variant="5f"       (no variant) variant="l8"|"l5l"  (no variant)
```

`id` returned to the dispatcher = `variant ?? dilinkFamily`. Empty
or `unknown` props collapse to `dilinkFamily="unknown"` and the
runtime falls back to the unscoped OpRoute (or "unsupported on
this model" if there isn't one).

## Why these specific props

- **`ro.byd.ui.splitscreen`** is the most load-bearing single
  value. It's `0` on every Di5.0 head unit and `1` on every Di5.1.
  When `0`, the OS doesn't expose the multi-display task-stack
  APIs (`am stack list`, `am stack move-task --display N`) we
  exploit for cluster ops. So this is the capability gate that
  decides whether `pkg.move`, `surface.am_start_cluster`, etc.
  even make sense to call.

- **`ro.vehicle.type.value`** is BYD's internal trim
  discriminator — an integer that distinguishes between trims
  within the same DiLink generation. `19` confirmed for 5f. We
  expect each L8 / L5L / Yuan / Han / etc. to have its own value
  in the same scheme. **Update this table** when each trim's value
  is observed on real hardware.

- **`ro.product.vendor.device`** + **`ro.vehicle.type`** are
  redundant for DiLink-family classification. We read both because
  some images stripped one or the other in past releases; the
  classifier accepts either signal.

## Adding a new trim

1. Extract the firmware ([`firmware-extraction.md`](./firmware-extraction.md)).
2. Pull `system/build.prop` and `vendor/build.prop`.
3. Add a column to the table above with the trim's name.
4. Decide on a `variant` slug (lowercase, short, no spaces — e.g.
   `yuan_pro`, `han_2024`).
5. Add the matching rule to `_classify` in
   `lib/platform/device/model_detector.dart`. Example:
   ```dart
   } else if (dilinkFamily == 'di5.1' && vehicleTypeValue == 23) {
     variant = 'yuan_pro';
   }
   ```
6. Add a unit test fixture in
   `test/core/device/model_detector_test.dart`.

## On-hardware verification commands

When you have a head unit on ADB:

```sh
# Pull the eight props the detector reads:
adb shell getprop ro.product.vendor.device
adb shell getprop ro.vehicle.type
adb shell getprop ro.vehicle.type.value
adb shell getprop ro.byd.ui.splitscreen
adb shell getprop ro.byd.ui.platformized
adb shell getprop ro.byd.ui.integrate
adb shell getprop ro.product.system.model
adb shell getprop ro.product.board

# Or all in one pass:
adb shell "getprop | grep -E 'vehicle|byd\\.ui|product\\.(vendor\\.device|system\\.model|board)'"
```

Compare against the table; if values diverge from the column for
the trim's claimed model, the firmware is a variant we haven't
profiled — add it.
