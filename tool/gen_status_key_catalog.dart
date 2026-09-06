// Generates StatusKeyCatalog.kt from the single Dart source:
//   bydStatusKeyFacet  (lib/sdk/brands/byd/byd_status_facet.dart) — the
//                       per-label deviceType + valueKind, and
//   bydStatusLabelToCatalog (byd_catalog.dart) — the label -> framework map.
//
// The Kotlin status-read catalog is thus DERIVED from the Dart catalog, so
// the label↔framework pairing can't drift between the two languages.
//
// Run:    dart run tool/gen_status_key_catalog.dart
// Verify: dart run tool/gen_status_key_catalog.dart --check   (CI guard;
//         exit 1 if the committed file differs from a fresh generation)
import 'dart:io';

import 'package:ilink/sdk/brands/byd/byd_catalog.dart';
import 'package:ilink/sdk/brands/byd/byd_status_facet.dart';

const _out =
    'android/app/src/main/kotlin/com/i99dev/ilink/car/StatusKeyCatalog.kt';

const _kindToKotlin = {
  SignalValueKind.intValue: 'INT',
  SignalValueKind.doubleValue: 'DOUBLE',
  SignalValueKind.bytes: 'BYTES',
  SignalValueKind.intArray: 'INT_ARRAY',
};

String _generate() {
  final rows = StringBuffer();
  bydStatusKeyFacet.forEach((label, facet) {
    final framework = bydStatusLabelToCatalog[label];
    if (framework == null) {
      stderr.writeln('FATAL: status label "$label" has no _entries framework');
      exit(2);
    }
    rows.writeln(
      '        RawEntry("$label", ${facet.deviceType}, '
      '"$framework", ValueKind.${_kindToKotlin[facet.valueKind]}),',
    );
  });

  return '''package com.i99dev.ilink.car

// GENERATED — do not edit by hand.
// Source of truth: lib/sdk/brands/byd/byd_status_facet.dart (deviceType +
// valueKind) + byd_catalog.dart (label -> framework). Regenerate with:
//   dart run tool/gen_status_key_catalog.dart
// CI fails if this file drifts from a fresh generation.

/**
 * Status-key catalog — the labels the daemon actively reads/pushes, each
 * with its BYD `device_type`, `featureName` (resolved at boot via
 * BydAutoFeatureIdsCatalog) and `valueKind`.
 *
 * Cross-trim safe by construction — names that don't resolve on a given
 * trim are silently dropped by [build].
 */
object StatusKeyCatalog {

    private data class RawEntry(
        val label: String,
        val deviceType: Int,
        val featureName: String,
        val valueKind: ValueKind,
    )

    private enum class ValueKind { INT, DOUBLE, BYTES, INT_ARRAY }

    private val raw: List<RawEntry> = listOf(
${rows.toString().trimRight()}
    )

    /** Resolve every entry against the framework catalog; drop
     *  unresolved names silently (feature absent on this trim).
     *  Built lazily on first access; results cached.  */
    val list: List<StatusKey> by lazy {
        raw.mapNotNull { e ->
            val key = BydAutoFeatureIdsCatalog.resolve(e.featureName) ?: return@mapNotNull null
            when (e.valueKind) {
                ValueKind.DOUBLE -> StatusKey.DoubleKey(label = e.label, dt = e.deviceType, key = key)
                ValueKind.BYTES -> StatusKey.BytesKey(label = e.label, dt = e.deviceType, key = key)
                ValueKind.INT_ARRAY -> StatusKey.IntArrayKey(label = e.label, dt = e.deviceType, key = key)
                ValueKind.INT -> StatusKey.IntKey(label = e.label, dt = e.deviceType, key = key)
            }
        }
    }
}
''';
}

void main(List<String> args) {
  final generated = _generate();
  final check = args.contains('--check');
  final file = File(_out);

  if (check) {
    final current = file.existsSync() ? file.readAsStringSync() : '';
    if (current.replaceAll('\r\n', '\n') !=
        generated.replaceAll('\r\n', '\n')) {
      stderr.writeln(
        'StatusKeyCatalog.kt is STALE — run: dart run tool/gen_status_key_catalog.dart',
      );
      exit(1);
    }
    stdout.writeln(
      'StatusKeyCatalog.kt up to date (${bydStatusKeyFacet.length} keys)',
    );
    return;
  }

  file.writeAsStringSync(generated);
  stdout.writeln('wrote $_out (${bydStatusKeyFacet.length} keys)');
}
