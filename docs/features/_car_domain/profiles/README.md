# Car Profiles

Two layers share the name "CarProfile" in this repo, and they answer
different questions. Keep the distinction sharp — bugs from confusing
the two are the most common car-side regression we ship.

| Layer | Question it answers | Source of truth | Lives at |
|---|---|---|---|
| **Static trim profile** | "What does *this trim* expose to mini-apps and platform plugins — display topology, passenger transport, content providers, rate-limit knobs?" | Hand-curated per-trim definitions backed by collector probes. | `android/.../car/profiles/CarProfile.kt` + `definitions/<Trim>.kt` |
| **Runtime capability profile** | "What works on the car *right now* — capability bitmask + per-action support — including the fallback the resolver landed on?" | 5-tier resolver over `ProfileKey` (DiLink → variant → sub-trim → fingerprint). | `android/.../car/CarProfile.kt` + Dart mirror `lib/features/_car_domain/profile/car_profile.dart` |

Both car-control reads and writes (see [`sdk/`](../../../sdk)) read both layers. The
runtime profile gives them the cap bitmask used for mini-app catalog
filtering and `CarCommandRouter` action support; the static profile
gives them the dispatcher choices (passenger transport, cluster path),
display picker UX, and rate-limit buckets.

## Topics

- [`static-profile.md`](static-profile.md) — the per-trim static
  profile. Sub-profiles (Display / Capability / RateLimit /
  ContentProvider / Triage), enums, and what each consumer reads.
- [`runtime-profile.md`](runtime-profile.md) — the runtime
  capability profile. `ProfileKey`, the 5-tier fallback chain,
  `capabilityBits`, and per-action support.
- [`detection.md`](detection.md) — how a trim is identified at
  boot. `outsw` / `vehicle40dCode` / `modelVariant` / `fingerprint`
  signal flow and how the active profile gets selected.
- [`adding-a-trim.md`](adding-a-trim.md) — step-by-step playbook
  for adding a new BYD trim end-to-end (probe → profile →
  detector → tests).
- [`catalog.md`](catalog.md) — quick-reference table of every
  trim profile in the registry today, with the load-bearing
  fields side by side.

## Related docs

- [`../sdk/`](../../../sdk) — the car-control SDK layers
  that consults both profile layers on every cross-trust read
  and every actuator write.
- [`../features/_car_domain/profiles/adding-a-trim-variant.md`](adding-a-trim-variant.md) — historical
  log of empirical fingerprint findings from on-car probes.
- [`../features/_car_domain/README.md`](../README.md) — actuator command
  semantics; orthogonal to profiles but uses them.
