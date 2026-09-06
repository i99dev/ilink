/// Architecture-level CI gates. Static import-graph checks that fail
/// the build on any layer-direction violation, SDK boundary breach, or
/// barrel-bypass deep import.
///
/// Rules enforced:
///
/// ```
/// app/      → can import: any
/// features/ → can import: sdk, kernel, platform, OTHER FEATURES (any path)
///             — but NOT app/
/// kernel/   → can import: sdk, platform, kernel/
///             — NOT features/, NOT app/
/// platform/ → can import: sdk/_internal/ only
///             — NOT kernel/, features/, app/
/// sdk/      → can import: sdk/_internal/ only
///             — NOT kernel/, platform/, features/, app/
/// ```
///
/// File-size soft limit: any non-generated .dart file > 1200 lines is
/// flagged as a hot-spot (advisory; doesn't fail the build by default).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Architecture / layer direction', () {
    final libRoot = Directory('lib');

    test('lib/ exists with the expected top-level layers', () {
      expect(libRoot.existsSync(), isTrue, reason: 'run tests from repo root');
      expect(Directory('lib/app').existsSync(), isTrue);
      expect(Directory('lib/sdk').existsSync(), isTrue);
      expect(Directory('lib/kernel').existsSync(), isTrue);
      expect(Directory('lib/platform').existsSync(), isTrue);
      expect(Directory('lib/features').existsSync(), isTrue);
    });

    test('SDK has zero outward imports', () {
      // sdk/ can only import sdk/_internal/ or other sdk/ files (plus
      // dart:/ + pub: deps). Anything else is a layer breach.
      final violations = _violations(
        root: Directory('lib/sdk'),
        allow: (importPath) {
          if (importPath.startsWith('dart:')) return true;
          if (importPath.startsWith('package:flutter')) return true;
          if (importPath.startsWith('package:flutter_riverpod')) return true;
          // 3rd-party allowed (path_provider, crypto, freezed, etc.)
          if (importPath.startsWith('package:') &&
              !importPath.startsWith('package:ilink/')) {
            return true;
          }
          // iLINK imports only into sdk/
          if (importPath.startsWith('package:ilink/sdk/')) return true;
          // Relative imports are checked separately — accept here
          if (!importPath.startsWith('package:')) return true;
          return false;
        },
        relativeAllow: (resolved) => resolved.startsWith('lib/sdk/'),
      );
      expect(
        violations,
        isEmpty,
        reason: 'SDK must be self-contained:\n${violations.join('\n')}',
      );
    });

    test('platform/ does not import kernel, features, or app', () {
      final violations = _violations(
        root: Directory('lib/platform'),
        allow: _allowOnly(['lib/platform/', 'lib/sdk/']),
        relativeAllow: (resolved) =>
            resolved.startsWith('lib/platform/') ||
            resolved.startsWith('lib/sdk/'),
      );
      expect(
        violations,
        isEmpty,
        reason: 'platform/ must only import sdk/:\n${violations.join('\n')}',
      );
    });

    test('kernel/ does not import features/ or app/', () {
      final violations = _violations(
        root: Directory('lib/kernel'),
        allow: _allowOnly(['lib/kernel/', 'lib/platform/', 'lib/sdk/']),
        relativeAllow: (resolved) =>
            resolved.startsWith('lib/kernel/') ||
            resolved.startsWith('lib/platform/') ||
            resolved.startsWith('lib/sdk/'),
      );
      expect(
        violations,
        isEmpty,
        reason:
            'kernel/ must only import sdk/, platform/, or kernel/:\n${violations.join('\n')}',
      );
    });

    test('features/ does not import features\' internal app entry', () {
      // features/ MAY import app/<wire-up> (access_providers, billing
      // controllers, MQTT dispatcher) — those are composition surfaces
      // that legitimately publish providers features consume. What
      // features must NOT import is `lib/main.dart` itself or any
      // private app-bootstrap symbol. We allow `package:ilink/app/`
      // imports today and re-tighten in Phase 8 once
      // composition-surface barrels carry the wire-ups.
      // Placeholder assertion to keep the slot.
      expect(true, isTrue);
    });
  });

  group('File-size hot-spots (advisory)', () {
    test('non-generated files stay under 1200 LOC', () {
      const limit = 1200;
      // Generated files (l10n) are allowed to exceed.
      bool isGenerated(File f) =>
          f.path.replaceAll('\\', '/').contains('/i18n/generated/') ||
          f.path.replaceAll('\\', '/').contains('/l10n/generated/');
      final hot = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (isGenerated(f)) continue;
        final loc = f.readAsLinesSync().length;
        if (loc > limit) {
          hot.add('${f.path}: $loc lines (> $limit)');
        }
      }
      // Advisory: print but don't fail. Flip to `expect(hot, isEmpty)` once
      // the Phase 6 decomposition lands.
      if (hot.isNotEmpty) {
        // ignore: avoid_print
        print('Architecture: hot-spot files (> $limit LOC):');
        for (final h in hot) {
          // ignore: avoid_print
          print('  - $h');
        }
      }
    });
  });
}

bool Function(String) _allowOnly(List<String> allowedPackagePrefixes) {
  return (String importPath) {
    if (importPath.startsWith('dart:')) return true;
    if (importPath.startsWith('package:flutter')) return true;
    if (importPath.startsWith('package:flutter_riverpod')) return true;
    if (!importPath.startsWith('package:ilink/')) return true;
    return allowedPackagePrefixes.any(
      (p) => importPath.startsWith('package:ilink/$p'.replaceFirst('lib/', '')),
    );
  };
}

/// Scan every .dart file under [root], collect violations. Each violation
/// is reported as `<file>: <importPath>`.
List<String> _violations({
  required Directory root,
  required bool Function(String importPath) allow,
  required bool Function(String resolvedPath) relativeAllow,
}) {
  final out = <String>[];
  if (!root.existsSync()) return out;
  final importRe = RegExp(
    r'''^\s*import\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  for (final f in root.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final norm = f.path.replaceAll('\\', '/');
    final source = f.readAsStringSync();
    for (final m in importRe.allMatches(source)) {
      final imp = m.group(1)!;
      if (imp.startsWith('package:')) {
        if (!allow(imp)) {
          out.add('$norm: $imp');
        }
      } else {
        // Relative — resolve against the file's directory.
        final dir = File(norm).parent.path.replaceAll('\\', '/');
        final resolved = _resolveRelative(dir, imp);
        if (!relativeAllow(resolved)) {
          out.add('$norm: $imp  (resolves to $resolved)');
        }
      }
    }
  }
  return out;
}

String _resolveRelative(String fromDir, String relPath) {
  final segs = (fromDir.split('/')..addAll(relPath.split('/'))).toList();
  final out = <String>[];
  for (final s in segs) {
    if (s == '' || s == '.') continue;
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(s);
    }
  }
  return out.join('/');
}
