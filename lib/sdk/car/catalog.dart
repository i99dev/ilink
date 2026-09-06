/// Brand-agnostic catalog interface.
///
/// Each brand adapter (`lib/sdk/brands/<brand>/<brand>_catalog.dart`)
/// implements [CarCatalog] by loading + parsing its
/// `.secrets/<brand>/catalog.tsv` + `catalog_meta.yaml` from
/// bundled assets.
///
/// Catalogs are static for the app's lifetime — load at boot, hold
/// in memory. ROM-update-aware: when the brand framework adds
/// features, dump a new catalog into `.secrets/<brand>/`, ship a
/// new APK; the catalog reload happens automatically.
library;

import 'feature.dart';

abstract class CarCatalog {
  /// Number of features in this catalog.
  int get size;

  /// Look up a feature by its full catalog name.
  /// Returns null when the name isn't in the catalog.
  CarFeature? feature(String name);

  /// All features as an iterable. Use sparingly — typical use case
  /// is finding by description / category, which has dedicated
  /// helpers below.
  Iterable<CarFeature> all();

  /// All features in a category (`"doors"`, `"climate"`, …).
  Iterable<CarFeature> byCategory(String category);

  /// All features in a namespace (`"Door"`, `"Bodywork"`, …).
  Iterable<CarFeature> byNamespace(String namespace);

  /// Distinct namespaces in the catalog, sorted alphabetically.
  List<String> namespaces();

  /// Distinct categories in the catalog (from catalog_meta.yaml
  /// overrides), sorted.
  List<String> categories();

  /// Search by partial description match — useful for "find me the
  /// battery percentage feature" without knowing the catalog name.
  /// Case-insensitive substring match on [CarFeature.description].
  Iterable<CarFeature> searchByDescription(String query);
}
