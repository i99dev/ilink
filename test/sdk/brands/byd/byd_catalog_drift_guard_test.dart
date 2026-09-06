import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/brands/byd/byd_catalog.dart';

/// W1 drift guard — locks `assets/byd/catalog.tsv` as the canonical read
/// catalog before the codegen.
///
/// Every framework name the gate reads ([bydStatusLabelToCatalog] values)
/// must resolve to a row in `catalog.tsv`; a name absent from the catalog
/// reads `null` at runtime — a silent gate/dashboard-tile failure. This
/// guard fails CI when a NEW such name is introduced.
///
/// Name-form note: `catalog.tsv` is inconsistent — some rows namespaced
/// (`Yun.YUN_CONFIG`), some raw (`AC_TEMP_MAIN`,
/// `STATISTIC_SOC_BATTERY_PERCENTAGE`) — while code names are namespaced.
/// So a code name resolves if EITHER its full form OR its
/// namespace-stripped form is present. (Canonicalising that inconsistency
/// is the next W1 step.)
///
/// NOTE: the public-catalog `_entries` are keyed by short *labels*
/// (`ac_power`), not framework names, so they are NOT checked here — they
/// map to framework names via [bydStatusLabelToCatalog], which is what the
/// guard validates.
void main() {
  final tsvNames = <String>{};
  for (final line in File('assets/byd/catalog.tsv').readAsLinesSync()) {
    final tab = line.indexOf('\t');
    if (tab >= 0) tsvNames.add(line.substring(0, tab));
  }

  String stripNs(String n) {
    final d = n.indexOf('.');
    return d < 0 ? n : n.substring(d + 1);
  }

  bool resolves(String n) =>
      tsvNames.contains(n) || tsvNames.contains(stripNs(n));

  // Gate→name targets known to be absent from catalog.tsv (each reads
  // null today). Allowlisted — not silently changed — because fixing
  // them is behaviour-changing and needs on-car verification:
  //   * AC_MAX_HEATING_STATE, CHARGING_DETACHABLE_PAD_REMAIN_STATUS —
  //     no catalog row at all (feature not in this catalog/ROM).
  //   * LIGHT_UNLOCK_WELCOME_SWITCH — the catalog has no readable status
  //     variant for unlock-welcome (only *_PREVIEW_EXECUTION, an action),
  //     so this gate field reads null. The lock-welcome side WAS fixed
  //     (→ *_STATUS, which exists); the unlock side has nothing to point
  //     at.
  const knownAbsent = {
    'Ac.AC_MAX_HEATING_STATE',
    'Charging.CHARGING_DETACHABLE_PAD_REMAIN_STATUS',
    'Light.LIGHT_UNLOCK_WELCOME_SWITCH',
  };

  test('catalog.tsv loaded', () {
    expect(tsvNames.length, greaterThan(10000));
  });

  test('every gate framework-name target resolves in catalog.tsv', () {
    final missing =
        bydStatusLabelToCatalog.values
            .where((n) => !resolves(n) && !knownAbsent.contains(n))
            .toSet()
            .toList()
          ..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'NEW gate→name drift — these read null at runtime: $missing. '
          'Add the row to catalog.tsv, or (if intentional) to knownAbsent '
          'with a reason.',
    );
  });

  test('knownAbsent allowlist does not rot (no entry that now resolves)', () {
    final nowResolving = knownAbsent.where(resolves).toList()..sort();
    expect(
      nowResolving,
      isEmpty,
      reason:
          'knownAbsent entries that catalog.tsv now covers — drop them from '
          'the allowlist: $nowResolving',
    );
  });
}
