# Per-model compatibility — research index

Reference for everything we know about BYD head-unit firmware
families and how the dash app dispatches per model. Land here when
you want to:

- Add support for a new trim (extract its firmware, identify the
  divergence axes, write the textproto override).
- Debug "works on L8, broken on L5L / 5f" reports — go to
  [`compatibility-matrix.md`](./compatibility-matrix.md) for the
  per-op support grid and the quick test recipe.
- Understand WHY a given op is gated to a specific model — the
  textproto's `model_match` field is the runtime mechanism; the
  rationale lives in [`build-prop.md`](./build-prop.md) and
  [`apk-catalog.md`](./apk-catalog.md).

## Models supported today

| Variant | DiLink | Android | ADAS map | Multi-display | Status |
|---|---|---|---|---|---|
| `l8`  | 5.1 | 13 | Huawei (`com.example.amapservice`) | yes | full support, primary baseline |
| `l5l` | 5.1 | 13 | BYD (`com.byd.naviauto`)            | yes | shipped via per-model textproto in v1.5.0-b |
| `5f`  | 5.0 | 12 | BYD (`com.byd.naviauto`)            | NO  | non-cluster ops only (display.*, gesture.*) |
| `unknown` (any other trim) | — | — | — | — | falls back to `dilinkFamily` route or "unsupported on this model" |

The runtime detector in `lib/platform/device/model_detector.dart`
classifies into these variants from `ro.product.vendor.device`,
`ro.vehicle.type`, `ro.vehicle.type.value`, and
`ro.byd.ui.splitscreen`. The dispatcher's `selectByModel`
([`MiniAppDispatcher.kt`](../../../android/app/src/main/kotlin/com/i99dev/ilink/miniapps/MiniAppDispatcher.kt))
picks the most-specific `model_match` set when multiple OpRoutes
share an op_token.

## Document map

| Doc | Use it for |
|---|---|
| [`firmware-extraction.md`](./firmware-extraction.md) | Step-by-step recipe to unpack a new BYD OTA ZIP and pull the data we need |
| [`build-prop.md`](./build-prop.md) | The exact prop keys + values that distinguish each trim |
| [`apk-catalog.md`](./apk-catalog.md) | Known BYD system apps, their packages, what they're for |
| [`compatibility-matrix.md`](./compatibility-matrix.md) | Per-op-per-model support grid + per-firmware test recipe |
| [`encryption-notes.md`](./encryption-notes.md) | What BYD encrypts in their OTAs and how that limits our static analysis |
| [`tools.md`](./tools.md) | The Python helpers we wrote for firmware analysis (`tools/ext4_extract.py`, `tools/ext4_catalog.py`) |

## Adding a new model — quick start

1. Get the firmware ZIP for the target trim. Check
   [`encryption-notes.md`](./encryption-notes.md) for which
   generation's payload is unpacked vs. encrypted.
2. Follow [`firmware-extraction.md`](./firmware-extraction.md) to
   get to `system.img` + an APK catalog.
3. Pull `build.prop` with the python helper; add the discovered
   trim to the table in [`build-prop.md`](./build-prop.md).
4. Identify which ops differ from L8's baseline. The 90% case is
   ADAS-map package + cluster-display marker. See
   [`compatibility-matrix.md`](./compatibility-matrix.md).
5. Write the per-model entries in `android/app/src/main/assets/offline/mini_app_table.textproto` — copy
   the `l5l` block in `mini_app_table.textproto` as a starting
   shape, replace `model_match: "l5l"` with the new variant id,
   replace the package name(s).
6. Add the variant detection rule to `lib/platform/device/model_detector.dart`
   `_classify`. Bump the test fixture set in
   `test/core/device/model_detector_test.dart`.
7. Verify on real hardware via the smoke checklist in
   [`compatibility-matrix.md`](./compatibility-matrix.md#smoke-test).

Each step is ~2–4 hours; the whole loop is one focused day per new
trim once the firmware is in hand.
