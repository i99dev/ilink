/// Brand-agnostic car SDK — public surface.
///
/// Import via:
///
/// ```dart
/// import 'package:ilink/sdk/car.dart';
/// ```
///
/// Re-exports the brand-agnostic interfaces ([CarFeature],
/// [CarCatalog], [CarClient], [CarBrand]) plus the reactive
/// providers consumers wire into.
///
/// Brand selection is automatic — at app boot the runtime probes
/// for known OEM frameworks (BYD's `bydauto.*`, Geely's
/// `geely.car.*`, …) and routes [carClientProvider] +
/// [carCatalogProvider] to the matching adapter. Add a brand by
/// dropping a folder under `lib/sdk/brands/<brand>/`.
library;

export 'car/brand.dart';
export 'car/catalog.dart';
export 'car/client.dart';
export 'car/feature.dart';
export 'car/providers.dart';
