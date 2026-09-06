/// Centralization regression gates (CI-failing).
///
/// `layer_test.dart` already enforces *import direction* between the
/// five layers. This file guards the *single-source-of-truth*
/// invariants the architecture review called out — the ones that decay
/// silently as features get added unless a test ratchets them:
///
///   1. HTTP: every `Dio` is built by the kernel factory, never bare
///      in a feature (the exact "four different patterns" regression
///      `dio_factory.dart` exists to prevent).
///   2. Maintainability ratchet: no NEW non-generated file crosses the
///      1200-LOC god-file line. Existing offenders are an explicit,
///      shrinking allowlist — not a moving target.
///   3. features/ never reach into `main.dart` (the app bootstrap is
///      not a public surface).
///
/// These are scans, not opinions: each failure prints the offending
/// `file:line` so the fix is mechanical.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `.dart` file under lib/, normalised to forward slashes.
Iterable<File> _libDartFiles() sync* {
  final root = Directory('lib');
  if (!root.existsSync()) return;
  for (final e in root.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) yield e;
  }
}

String _norm(String path) => path.replaceAll('\\', '/');

bool _isGenerated(String norm) =>
    norm.contains('/i18n/generated/') ||
    norm.contains('/l10n/generated/') ||
    norm.contains('/_proto/');

/// Known >1200-LOC non-generated files at the time this gate landed.
/// This set may SHRINK as files get decomposed; it must never GROW.
/// Adding an entry requires a deliberate review — that friction is the
/// point.
const _godFileAllowlist = <String>{
  // Hand-maintained BYD signal catalog — schema-shaped data, not
  // branching logic; decomposition tracked separately.
  'lib/sdk/brands/byd/byd_catalog.dart',
  // Voice broker state machine — cohesive VAD→STT→LLM→TTS pipeline;
  // split tracked in the Phase 6 decomposition note.
};

void main() {
  group('HTTP client centralization', () {
    test('Dio is only constructed inside lib/kernel/api/', () {
      // The factory (dio_factory.dart) is the one place allowed to call
      // the `Dio(...)` constructor. Anywhere else = a feature rolling
      // its own client with inconsistent timeouts/auth — the precise
      // thing the factory's own doc-comment forbids.
      final ctorRe = RegExp(r'\bDio\s*\(');
      final offenders = <String>[];
      for (final f in _libDartFiles()) {
        final norm = _norm(f.path);
        if (norm.startsWith('lib/kernel/api/')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          // `Dio dio` (a type annotation / parameter) is fine; only a
          // constructor call `Dio(` is a violation.
          if (ctorRe.hasMatch(line)) {
            offenders.add('$norm:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Bare Dio() outside the kernel factory. Use '
            'ref.watch(dioProvider(DioPurpose.<x>)):\n${offenders.join('\n')}',
      );
    });
  });

  group('Maintainability ratchet', () {
    test('no NEW non-generated file exceeds 1200 LOC', () {
      const limit = 1200;
      final overLimit = <String>[];
      for (final f in _libDartFiles()) {
        final norm = _norm(f.path);
        if (_isGenerated(norm)) continue;
        final loc = f.readAsLinesSync().length;
        if (loc > limit && !_godFileAllowlist.contains(norm)) {
          overLimit.add('$norm: $loc lines (> $limit)');
        }
      }
      expect(
        overLimit,
        isEmpty,
        reason:
            'New god-file(s) over $limit LOC. Decompose, or — only with '
            'review — add to the allowlist:\n${overLimit.join('\n')}',
      );
    });

    test('the allowlist itself has not silently grown', () {
      // Guards the guard: padding the allowlist to dodge the ratchet
      // trips this in the same diff. Lower the bound when a file is
      // decomposed and removed from the set.
      expect(
        _godFileAllowlist.length,
        lessThanOrEqualTo(1),
        reason: 'The 1200-LOC allowlist should shrink over time, not grow.',
      );
      // Every allowlisted path must still exist + still be over the
      // line — a stale entry (file deleted or shrunk) should be removed.
      for (final path in _godFileAllowlist) {
        final f = File(path);
        expect(f.existsSync(), isTrue, reason: 'stale allowlist entry: $path');
        expect(
          f.readAsLinesSync().length,
          greaterThan(1200),
          reason:
              '$path no longer exceeds 1200 LOC — drop it from the '
              'allowlist so the ratchet keeps tightening.',
        );
      }
    });
  });

  group('App-bootstrap is not a public surface', () {
    test('features/ never imports lib/main.dart', () {
      final mainImportRe = RegExp(
        r'''import\s+['"](package:ilink/main\.dart|(?:\.\./)+main\.dart)['"]''',
      );
      final offenders = <String>[];
      for (final f in _libDartFiles()) {
        final norm = _norm(f.path);
        if (!norm.startsWith('lib/features/')) continue;
        if (mainImportRe.hasMatch(f.readAsStringSync())) {
          offenders.add(norm);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'features/ must not import the app bootstrap (main.dart):\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
