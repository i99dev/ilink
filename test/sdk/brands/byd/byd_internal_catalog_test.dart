import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/brands/byd/byd_internal_catalog.dart';

/// Exercises [BydCatalog.fromContent] against the real bundled assets,
/// guarding the name-form normalisation: catalog.tsv mixes namespaced
/// (`Yun.YUN_CONFIG`) and raw (`STATISTIC_SOC_BATTERY_PERCENTAGE`) rows,
/// while `catalog_meta.yaml` keys everything namespaced. A raw-form row
/// must still pick up its namespaced metadata override.
void main() {
  late BydCatalog catalog;

  setUpAll(() {
    // Test runs at the package root, so the bundled assets are readable
    // directly (no rootBundle binding needed — that's why fromContent is
    // split out of load()).
    final tsv = File('assets/byd/catalog.tsv').readAsStringSync();
    final meta = File('assets/byd/catalog_meta.yaml').readAsStringSync();
    catalog = BydCatalog.fromContent(tsv, meta);
  });

  test('loads the full catalog', () {
    expect(catalog.size, greaterThan(10000));
  });

  test('raw-form row picks up its namespaced meta override', () {
    // STATISTIC_SOC_BATTERY_PERCENTAGE is RAW in catalog.tsv; its meta is
    // keyed `Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE`. Before the
    // dual-index fix the override silently missed (humanised desc, no
    // unit/category).
    final soc = catalog.feature('STATISTIC_SOC_BATTERY_PERCENTAGE');
    expect(soc, isNotNull);
    expect(soc!.description, 'Battery state of charge');
    expect(soc.unit, '%');
    expect(soc.category, 'battery');
  });
}
