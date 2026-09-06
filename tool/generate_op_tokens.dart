// Generates `lib/features/mini_apps/bridge/mini_app_op_tokens.g.dart`
// from `tool/mini_app_op_index.txt`.
//
// Each token is `sha256("mini_app_op:" + family + "." + op).take(16)` —
// the same formula the encrypted textproto and the Kotlin runtime use
// (EncryptedMiniAppTableSource.byToken). Deterministic over the index
// file — re-running with the same inputs produces a byte-identical
// .g.dart so the build cache + CI diff stay clean.
//
// Run from the dash repo root:
//
//   dart run tool/generate_op_tokens.dart
//
// Idempotent. Safe to run on every build; the pre-commit hook can call
// it to check the .g.dart is in sync with the index file.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _indexPath = 'tool/mini_app_op_index.txt';
const _dartOutputPath =
    'lib/features/mini_apps/bridge/mini_app_op_tokens.g.dart';
const _kotlinOutputPath =
    'android/app/src/main/kotlin/com/i99dev/ilink/miniapps/MiniAppOpToken.g.kt';

void main(List<String> args) {
  final entries = _readIndex();
  if (entries.isEmpty) {
    stderr.writeln('generate_op_tokens: $_indexPath has no entries');
    exit(1);
  }
  File(_dartOutputPath).writeAsStringSync(_emitDart(entries), flush: true);
  stderr.writeln('generate_op_tokens: wrote $_dartOutputPath');
  File(_kotlinOutputPath).writeAsStringSync(_emitKotlin(entries), flush: true);
  stderr.writeln(
    'generate_op_tokens: wrote $_kotlinOutputPath (${entries.length} ops)',
  );
}

class _Entry {
  _Entry(this.family, this.op);
  final String family;
  final String op;

  String get fullName => '$family.$op';
  String get token {
    final input = utf8.encode('mini_app_op:$fullName');
    final digest = sha256.convert(input).bytes;
    final hex = StringBuffer();
    for (final b in digest.take(8)) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  String get dartIdentifier {
    final parts = '$family.$op'.split(RegExp(r'[._]'));
    final head = parts.first.toLowerCase();
    final tail = parts.skip(1).map(_capitalize).join();
    return head + tail;
  }

  /// SCREAMING_SNAKE for Kotlin constants — avoids any chance of
  /// collision with Dart camelCase identifiers in the same pipeline.
  String get kotlinIdentifier =>
      '$family.$op'.replaceAll('.', '_').toUpperCase();

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

List<_Entry> _readIndex() {
  final lines = File(_indexPath).readAsLinesSync();
  final entries = <_Entry>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final dot = line.indexOf('.');
    if (dot <= 0 || dot == line.length - 1) {
      stderr.writeln('generate_op_tokens: malformed line "$raw"');
      exit(1);
    }
    entries.add(_Entry(line.substring(0, dot), line.substring(dot + 1)));
  }
  return entries;
}

String _emitDart(List<_Entry> entries) {
  final sorted = [...entries]..sort((a, b) => a.fullName.compareTo(b.fullName));
  final sb = StringBuffer();
  sb.writeln('// GENERATED FILE — do not edit by hand.');
  sb.writeln('// Source: tool/mini_app_op_index.txt');
  sb.writeln('// Regenerate: dart run tool/generate_op_tokens.dart');
  sb.writeln();
  sb.writeln('/// Stable 16-hex tokens for every mini-app native-capability');
  sb.writeln('/// op. The Dart-side family executor passes only these tokens');
  sb.writeln('/// through the method channel; the Kotlin dispatcher resolves');
  sb.writeln('/// token -> OpRoute via the encrypted table.');
  sb.writeln('///');
  sb.writeln('/// Replaces plaintext op names like "pkg.launch_on_display" so');
  sb.writeln('/// the Dart AOT snapshot does not reveal the family namespace.');
  sb.writeln('class MiniAppOpToken {');
  sb.writeln('  const MiniAppOpToken._();');
  sb.writeln();
  for (final e in sorted) {
    sb.writeln('  /// ${e.fullName}');
    sb.writeln('  static const String ${e.dartIdentifier} = \'${e.token}\';');
    sb.writeln();
  }
  sb.writeln('  /// All known tokens. Kept in sync with the index file.');
  sb.writeln('  static const List<String> all = <String>[');
  for (final e in sorted) {
    sb.writeln('    ${e.dartIdentifier},');
  }
  sb.writeln('  ];');
  sb.writeln('}');
  return sb.toString();
}

String _emitKotlin(List<_Entry> entries) {
  final sorted = [...entries]..sort((a, b) => a.fullName.compareTo(b.fullName));
  final sb = StringBuffer();
  sb.writeln('// GENERATED FILE — do not edit by hand.');
  sb.writeln('// Source: tool/mini_app_op_index.txt');
  sb.writeln('// Regenerate: dart run tool/generate_op_tokens.dart');
  sb.writeln();
  sb.writeln('package com.i99dev.ilink.miniapps');
  sb.writeln();
  sb.writeln('/**');
  sb.writeln(
    ' * Stable 16-hex tokens for every mini-app native-capability op.',
  );
  sb.writeln(' * Used by [MiniAppShellCommands] to look up op routes via');
  sb.writeln(' * [MiniAppDispatcher.resolveByToken] instead of the plaintext');
  sb.writeln(' * (familyId, opId) pair — keeps op names out of classes.dex.');
  sb.writeln(' */');
  sb.writeln('object MiniAppOpToken {');
  for (final e in sorted) {
    sb.writeln('    /** ${e.fullName} */');
    sb.writeln('    const val ${e.kotlinIdentifier} = "${e.token}"');
  }
  sb.writeln('}');
  return sb.toString();
}
