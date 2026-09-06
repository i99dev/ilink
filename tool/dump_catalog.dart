/// Emits `doc-sdk-ilink/public/data/catalog.json` from the live
/// `BydPublicCatalog` — the single source of truth at
/// `lib/sdk/brands/byd/byd_catalog.dart`.
///
/// Why a Dart regen tool (vs. the JS `import-byd-catalog.mjs` in
/// the docs repo)? Two reasons:
///
/// 1. It uses the SAME class miniapps see at runtime. Whatever
///    `client.car.list()` returns, this tool serialises — no
///    parallel parser that can drift.
/// 2. The catalog file's only import is
///    `lib/sdk/car/public_catalog.dart`, which has no Flutter
///    dependency. `dart run tool/dump_catalog.dart` works without
///    a Flutter SDK.
///
/// Usage (from car-iLINK root):
///
///   dart run tool/dump_catalog.dart
///
/// Override the output path with `--out=…` or `DOC_SDK_DIR=…`:
///
///   dart run tool/dump_catalog.dart --out=../doc-sdk-ilink/public/data/catalog.json
library;

import 'dart:convert';
import 'dart:io';

import 'package:ilink/sdk/brands/byd/byd_catalog.dart';

void main(List<String> args) {
  // Resolve output path. Priority: --out flag > DOC_SDK_DIR env >
  // conventional sibling location.
  String? outArg;
  for (final a in args) {
    if (a.startsWith('--out=')) outArg = a.substring('--out='.length);
  }
  final outPath = _resolveOutPath(outArg);

  final catalog = BydPublicCatalog.build();
  final entries = catalog.all().toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  // Duplicate guard — should be impossible (Dart side enforces),
  // but fail loudly if it ever drifts.
  final seen = <String>{};
  for (final e in entries) {
    if (!seen.add(e.name)) {
      stderr.writeln('FATAL: duplicate catalog name "${e.name}"');
      exit(1);
    }
  }

  // Each entry's toJson() already matches the docs page's wire shape
  // (name, category, description, units?, range?, writeable,
  // writeActionId?, threeD). Pass it through verbatim.
  final encoded = const JsonEncoder.withIndent(
    '  ',
  ).convert(entries.map((e) => e.toJson()).toList());

  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$encoded\n');

  final threeDCount = entries.where((e) => e.threeD).length;
  final writeCount = entries.where((e) => e.writeable).length;
  final byCat = <String, int>{};
  for (final e in entries) {
    byCat[e.category] = (byCat[e.category] ?? 0) + 1;
  }
  stdout.writeln(
    'wrote $outPath — ${entries.length} entries '
    '($threeDCount 3D, $writeCount writeable)',
  );
  final sortedCats = byCat.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sortedCats) {
    stdout.writeln('  ${e.key.padRight(14)} ${e.value}');
  }
}

String _resolveOutPath(String? cliArg) {
  if (cliArg != null && cliArg.isNotEmpty) return cliArg;
  final envDir = Platform.environment['DOC_SDK_DIR'];
  if (envDir != null && envDir.isNotEmpty) {
    return '$envDir/public/data/catalog.json';
  }
  final candidates = [
    '../doc-sdk-ilink/public/data/catalog.json',
    '../../doc-sdk-ilink/public/data/catalog.json',
  ];
  for (final p in candidates) {
    final parent = Directory(File(p).parent.path);
    if (parent.parent.parent.existsSync()) return p;
  }
  return candidates.first;
}
