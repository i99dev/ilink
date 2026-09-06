/// Riverpod wiring for the brand-routed [PublicCatalog].
///
/// Watches [currentBrandProvider]; rebuilds the catalog when the
/// active brand switches (e.g. a Geely-trim install on a multi-brand
/// build). Catalogs are tiny (~200 entries, all in-memory) so
/// rebuilding is free.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'brand.dart';
import 'public_catalog.dart';
import '../brands/byd/byd_catalog.dart';

final publicCatalogProvider = Provider<PublicCatalog>((ref) {
  final brand = ref
      .watch(currentBrandProvider)
      .maybeWhen(data: (b) => b, orElse: () => CarBrand.byd);
  switch (brand) {
    case CarBrand.byd:
    case CarBrand.geely: // until Geely ships its own catalog
    case CarBrand.nio:
    case CarBrand.tesla:
    case CarBrand.unknown:
      return BydPublicCatalog.build();
  }
});
