/// Guards the codegen contract for `StatusKeyCatalog.kt`.
///
/// `StatusKeyCatalog.kt` is GENERATED from one Dart source —
/// `bydStatusKeyFacet` (deviceType + valueKind) + `bydStatusLabelToCatalog`
/// (label → framework) — by `tool/gen_status_key_catalog.dart`. These tests
/// fail if (a) a facet label has no catalog framework (the generator would
/// FATAL), or (b) the committed Kotlin has drifted from a fresh generation
/// (someone edited the facet without regenerating). This replaces the old
/// hand-sync test between the two languages — the data is now single-source.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/brands/byd/byd_status_facet.dart';
import 'package:ilink/sdk/brands/byd/byd_status_labels.dart';

const _kindToKotlin = {
  SignalValueKind.intValue: 'INT',
  SignalValueKind.doubleValue: 'DOUBLE',
  SignalValueKind.bytes: 'BYTES',
  SignalValueKind.intArray: 'INT_ARRAY',
};

void main() {
  test('every status-facet label resolves to a catalog framework', () {
    final unresolved = bydStatusKeyFacet.keys
        .where((label) => bydStatusLabelToCatalog[label] == null)
        .toList();
    expect(
      unresolved,
      isEmpty,
      reason:
          'These status-facet labels have no _entries framework, so the '
          'generator would emit nothing (or FATAL). Add a catalog row or '
          'drop the facet key:\n${unresolved.join('\n')}',
    );
  });

  test('StatusKeyCatalog.kt matches a fresh generation (no drift)', () {
    final kt = File(
      'android/app/src/main/kotlin/com/i99dev/ilink/car/StatusKeyCatalog.kt',
    );
    expect(kt.existsSync(), isTrue, reason: 'run from car-ilink/ root');
    final source = kt.readAsStringSync();

    // Every facet entry must appear as its generated RawEntry line.
    final missing = <String>[];
    bydStatusKeyFacet.forEach((label, facet) {
      final framework = bydStatusLabelToCatalog[label]!;
      final expected =
          'RawEntry("$label", ${facet.deviceType}, '
          '"$framework", ValueKind.${_kindToKotlin[facet.valueKind]}),';
      if (!source.contains(expected)) missing.add(expected);
    });
    expect(
      missing,
      isEmpty,
      reason:
          'StatusKeyCatalog.kt is STALE — regenerate with '
          '`dart run tool/gen_status_key_catalog.dart`. Missing rows:\n'
          '${missing.take(10).join('\n')}',
    );

    // And no EXTRA rows the facet doesn't account for (count parity).
    final rowCount = RegExp(
      r'RawEntry\(',
    ).allMatches(source).where((m) => true).length;
    // Subtract the `data class RawEntry(` declaration line.
    expect(
      rowCount - 1,
      bydStatusKeyFacet.length,
      reason:
          'StatusKeyCatalog.kt has ${rowCount - 1} RawEntry rows but the '
          'facet declares ${bydStatusKeyFacet.length}. Regenerate.',
    );
  });
}
