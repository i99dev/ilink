import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Architectural test: the generated op-token files must match the
/// hand-maintained index. If they drift, regenerate via:
///
///   dart run tool/generate_op_tokens.dart
///
/// Why this matters: the textproto seed in `.secrets/mini_app_table/`
/// pins each `op_token` to the sha256-derived value that the Dart +
/// Kotlin sides use to look it up. A drift between the index and the
/// generated files would silently route the migrated handler through
/// the legacy hardcoded fallback (which exists in the binary), defeating
/// the whole APK-decompile-resistance goal.
///
/// Three checks per build:
///   1. Every index entry yields a constant in
///      `lib/features/mini_apps/bridge/mini_app_op_tokens.g.dart`.
///   2. Every index entry yields a constant in
///      `android/.../miniapps/MiniAppOpToken.g.kt`.
///   3. Each constant value equals
///      `sha256("mini_app_op:" + family + "." + op).take(16)`.
///
/// Run from project root: `flutter test test/features/mini_apps/op_tokens_in_sync_test.dart`
void main() {
  test('op-token files match tool/mini_app_op_index.txt', () {
    final entries = _readIndex('tool/mini_app_op_index.txt');
    expect(entries, isNotEmpty, reason: 'index file is empty');

    final dartSrc = File(
      'lib/features/mini_apps/bridge/mini_app_op_tokens.g.dart',
    ).readAsStringSync();
    final kotlinSrc = File(
      'android/app/src/main/kotlin/com/i99dev/ilink/miniapps/MiniAppOpToken.g.kt',
    ).readAsStringSync();

    for (final entry in entries) {
      final expected = _computeToken(entry.fullName);
      // Dart side: `static const String <camelCase> = '<token>';`
      expect(
        dartSrc.contains("'$expected'"),
        isTrue,
        reason:
            'mini_app_op_tokens.g.dart missing token for ${entry.fullName} '
            '(expected $expected). Re-run: dart run tool/generate_op_tokens.dart',
      );
      // Kotlin side: `const val <SCREAMING_SNAKE> = "<token>"`
      expect(
        kotlinSrc.contains('"$expected"'),
        isTrue,
        reason:
            'MiniAppOpToken.g.kt missing token for ${entry.fullName} '
            '(expected $expected). Re-run: dart run tool/generate_op_tokens.dart',
      );
    }
  });

  test('no plaintext op names in migrated mini-app helpers', () {
    // Allow-listed: the loader, dispatcher, generator output, and the
    // observability scrubber (which lists the plaintext patterns
    // *because* it redacts them — listing them is the whole point).
    const exempt = <String>{
      'lib/features/mini_apps/bridge/mini_app_op_tokens.g.dart',
      'lib/platform/observability/observability.dart',
    };
    // Plaintext op-name patterns we don't want appearing in lib/ outside
    // the exempt list. Each entry is an index `family.op` from the
    // op-index — enforced literally so a future migration that
    // accidentally introduces one is caught.
    final entries = _readIndex('tool/mini_app_op_index.txt');
    final offenders = <String>[];
    for (final dartFile in Directory(
      'lib',
    ).listSync(recursive: true, followLinks: false)) {
      if (dartFile is! File) continue;
      if (!dartFile.path.endsWith('.dart')) continue;
      final rel = dartFile.path
          .replaceAll(r'\', '/')
          .replaceFirst(RegExp(r'^\./'), '');
      if (exempt.contains(rel)) continue;
      final src = dartFile.readAsStringSync();
      for (final entry in entries) {
        if (src.contains(entry.fullName)) {
          offenders.add('$rel mentions ${entry.fullName}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'plaintext op names found in Dart sources — use MiniAppOpToken.* '
          'from mini_app_op_tokens.g.dart instead.\n${offenders.join('\n')}',
    );
  });
}

class _IndexEntry {
  _IndexEntry(this.family, this.op);
  final String family;
  final String op;
  String get fullName => '$family.$op';
}

List<_IndexEntry> _readIndex(String path) {
  final out = <_IndexEntry>[];
  for (final raw in File(path).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final dot = line.indexOf('.');
    if (dot <= 0) continue;
    out.add(_IndexEntry(line.substring(0, dot), line.substring(dot + 1)));
  }
  return out;
}

String _computeToken(String fullName) {
  final input = utf8.encode('mini_app_op:$fullName');
  final digest = sha256.convert(input).bytes;
  final sb = StringBuffer();
  for (final b in digest.take(8)) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
