# Trim catalog — quick reference

Every static trim profile in `CarProfileRegistry` today, side by
side. Source files live under
[`car/profiles/definitions/`](../../../../android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/definitions/).

## Identity

| variantId | Family name | DiLink | Code40d | modelVariant | Powertrain |
|---|---|---|---|---|---|
| `l8` | Leopard 8 | Di5.1 | `155` | `fcbsq` | Phev |
| `l5` | Leopard 5 | Di5.0 | `153` | `fcbsf` | Phev |
| `l5l` | Leopard 5 Lidar | Di5.1 | – | – | Phev |
| `l5u` | Leopard 5 Ultra | Di5.1 | – | – | Phev |
| `l7` | Leopard 7 | Di5.1 | – | – | Phev |
| `han_l` | BYD HAN L | Di5.1 | – | – | Phev |
| `song_plus` | Song PLUS | Di5.0 | `243` | – | Phev |
| `5f` | F-series | Di5.0 | – | – | Unknown |
| *(null)* | Generic BYD DiLink | Unknown | – | – | Unknown |

## Capability surfaces

| variantId | Passenger | Cluster | showCluster | showFission2 |
|---|---|---|---|---|
| `l8` | Fission | `{Pixel}` | true | true |
| `l5` | SyntheticSwipe | `{Icons}` | false | false |
| `l5l` | Fission | `{Pixel, Icons}` | true | true |
| `l5u` | SyntheticSwipe | `{Icons}` | false | false |
| `l7` | Fission | `{}` | false | true |
| `han_l` | Fission | `{}` | false | true |
| `song_plus` | Fission † | `{}` | false | true |
| `5f` | None | `{}` | false | false |
| *(null)* | Fission | `{Pixel}` | true | true |

† Song PLUS passenger transport is currently `Fission` based on
its XDJA-display-name evidence, but the BYD-container topology
matches L5 (which uses `SyntheticSwipe`). On-car launch test
pending — see KDoc in `definitions/SongPlus.kt`.

## Display topology

| variantId | hiddenDisplayIds | secondaryDisplayOwners (owner → role) |
|---|---|---|
| `l8` | `{3, 4}` | `com.xdja.containerservice → cluster` |
| `l5` | `{}` | `com.byd.containerservice → passenger` |
| `l5l` | `{3, 4}` | `com.xdja.containerservice → cluster` |
| `l5u` | `{}` | `{}` |
| `l7` | `{2}` | `{}` |
| `han_l` | `{2}` | `{}` |
| `song_plus` | `{}` | `com.byd.containerservice → passenger` |
| `5f` | `{}` | `{}` |
| *(null)* | `{}` | `{}` (Generic — refuses to auto-classify unprofiled trims) |

## Read this table when…

- **A mini-app render bug only reproduces on one trim** — check
  the row's display columns for hidden / remap surprises.
- **A pkg-launcher cast doesn't reach the passenger panel** —
  the `Passenger` column tells you which transport the dispatcher
  picked. If it's `SyntheticSwipe`, the event path goes through
  `MultiTouchInjector → DishareTransport.cast`, NOT
  `setLaunchDisplayId`.
- **The cluster surface is missing** — `showCluster=false` means
  the OS doesn't expose a usable cluster on that trim. The
  `Cluster` column tells you which paths exist (Pixel /
  Icons / both / none).
- **Sentry events from a fleet trim are unattributed** — the
  `car.variant` / `car.dilink` tags come from the Dart model
  detector (not the profile). If the detector can't resolve the
  trim, add its `(carType, vehicleId)` row to `model_detector`.

## Adding a new trim to this table

When a new trim ships in `CarProfileRegistry.ALL`, add a row to
all three sub-tables here. Keep the row order consistent across
sub-tables so the eye can scan a single trim across capability
surfaces and display topology together.

See [`adding-a-trim.md`](adding-a-trim.md) for the full PR
checklist.
