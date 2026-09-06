# Feature-id discovery — capture once, ship as data

> Sister doc: see [`../sdk/`](../../../sdk) for how the captured
> live-feature dump is consumed by the runtime SDK.

The BYD framework exposes ~21k catalog entries (`Door.DOOR_LOCK_…`,
`Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE`, …). Of those, only ~9.5k
are actually live on a given trim. Until now, the live set was
discovered at runtime on every cold boot via `AutoCarRegistry`, which
brute-force probes every catalog name in 5–10 s before the dashboard
can paint anything.

This directory replaces that runtime discovery with a one-time capture:

  - per-trim `*.tsv` files listing every name we observed live on that
    trim (with sample value at capture time)
  - the SDK seeds from these files at boot — **no runtime probe**
  - `AutoCarRegistry` survives only as the diagnostic-screen
    observability surface; the production data path no longer depends
    on it

## Why static beats runtime discovery

| | Runtime registry | Static dump |
|---|---|---|
| Cold-boot delay before first paint | 5–10 s | 30 ms (one batched daemon read of the warm set) |
| "Registry is empty" failure mode | Yes (probe slower than first widget mount) | None |
| Cross-trim safety | Implicit (per-car probe) | Explicit (per-trim file under version control) |
| Code surface | ~600 lines (AutoCarRegistry + watchdog + cache) | One asset file + a static map |
| Adding a new car trim | Ship & probe in production | Capture once via the dump script, commit, ship |

The framework catalog itself never changes per-car — only the *live
subset* does. That subset is intrinsic to a trim, not a per-device
property, so capturing it once per trim is the right granularity.

## Files

  - `<trim>.tsv` — live-feature dump for one trim. Format is identical
    to `assets/byd/catalog.tsv` (`name<TAB>id`) plus an optional
    third column with the sample value at capture time. One file per
    `(brand, dilink_family, sub_trim)` tuple. Used by the SDK boot
    seed.

  - `dump.sh` — capture script. Runs against a live car; writes the
    `<trim>.tsv` file + a small metadata JSON. See "Capturing a new
    trim" below.

## Capturing a new trim

Pre-req: the target car is reachable over ADB and the daemon is up.

```sh
# from the repo root, with the target car at $TARGET (default
# 192.168.4.72:5555):
TARGET=192.168.4.72:5555 ./docs/features/_car_domain/feature-ids/dump.sh leopard8_dilink5.1
```

This produces:

  - `docs/features/_car_domain/feature-ids/leopard8_dilink5.1.tsv` — live-feature list
  - `docs/features/_car_domain/feature-ids/leopard8_dilink5.1.meta.json` — capture metadata
    (date, dilink version, total/live counts, daemon version)

The capture flow:

  1. The script asks the running app (via the diagnostic API the
     Auto Registry screen already uses) for the registry's full
     `name → value` snapshot.
  2. It waits up to 30 s for the registry's first scan to complete
     (one-time cost — only paid by the engineer doing the capture).
  3. Once the snapshot is non-empty, it writes the TSV and metadata.

Commit both files. The SDK at next boot will seed from this list
instead of the registry — every device on this trim sees the new
warm set immediately.

## Removing AutoCarRegistry from production

Staged so we can verify each step on a real car without losing
observability.

### Stage 1 — bypass (✓ done)

  - SDK seeds from a slim hardcoded warm-set list
    (`bydBootWarmSet` in `lib/sdk/brands/byd/byd_status_labels.dart`)
    instead of `transport.allFeaturesAuto()`
  - The host-side `getValueByName` already has a registry-free
    fallback (`AutoFeatureService.kt:202–209` — resolves via
    `BydAutoFeatureIdsCatalog.resolve` + `WARM_DT_FALLBACK`)
  - Auto Registry diagnostic screen is marked informational

The dashboard data path runs fine even when the registry is empty.
The registry's only contribution today is faster first reads when
its hot cache happens to have the value (skipped — same daemon
round-trip cost as a fallback).

### Capturing another trim

Use the read-only dump helper on an explicitly identified device. Record the firmware/model and retain the captured data locally for comparison. Adding a new bundled capture or changing warm-set behavior requires a separate verified source change; the release preparation script has no catalog-generation stage.

## Why we keep the diagnostic screen

The Auto Registry diagnostic page is genuinely useful when bringing up
a new trim: it shows what the brute-force probe finds *right now*,
which is the input to producing a new `<trim>.tsv` capture. It's also
the canary for "is this car actually responding to the BYD framework
at all" — an empty result there points at a daemon / framework issue,
not an SDK bug.

So the registry stays *in code*, just not *in the data path*. The
screen becomes "show me what runtime discovery would find" rather than
"show me what the dashboard is reading." Different question, different
answer, both legitimate.

## Where this fits in the SDK story

  - `assets/byd/catalog.tsv` — every name BYD's framework knows
    (universal, ROM-versioned). This is the "what could exist".
  - `docs/features/_car_domain/feature-ids/<trim>.tsv` — every name actually live on a
    specific trim. This is the "what does exist on THIS car".
  - SDK hot cache (`BydClient._values`) — every name we've actually
    read or had pushed to us. This is the "what we've seen".

Three layers, each strictly a subset of the previous. No runtime
discovery in the production path; runtime discovery survives only as
the bring-up tool that produces layer 2.
