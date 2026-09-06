import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architectural test: every mini-app install / uninstall must go
/// through `MiniAppInstallGate`. New code that calls
/// `miniAppCatalogProvider.notifier.install` / `.uninstall` directly
/// fails this test, forcing a typed [InstallCaller] entry point.
///
/// Carve-outs (file paths exempt from the rule, all documented):
///   * The gate implementation itself.
///   * `mini_app_providers.dart` — the catalog notifier IS the install
///     pipeline; the gate delegates to it after running pre-checks.
///   * `privileged_install_orchestrator.dart` — privileged path the
///     gate routes to (its internals don't loop back through the
///     gate; it's the "downstream" side of the gate's branch).
///
/// Grep-equivalent in CI:
///   grep -rE "miniAppCatalogProvider\.notifier\)?.(install|uninstall)\(" \
///     --include='*.dart' lib/ | exempt-list-filter | wc -l == 0
void main() {
  const projectRoot = 'lib';
  const exemptPaths = <String>{
    // The gate itself.
    'lib/features/mini_apps/state/mini_app_install_gate.dart',
    // The catalog notifier — owns the install pipeline. The gate
    // delegates to it after running pre-checks.
    'lib/features/mini_apps/state/mini_app_providers.dart',
  };

  test(
    'no direct miniAppCatalogProvider.install/.uninstall outside the gate',
    () async {
      final offenders = await _scan(
        projectRoot: projectRoot,
        exemptPaths: exemptPaths,
        pattern: RegExp(
          r'miniAppCatalogProvider\.notifier\)?\s*\.\s*(install|uninstall|reinstall)\s*\(',
        ),
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'Direct miniAppCatalogProvider install/uninstall detected.\n'
            'Use MiniAppInstallGate via miniAppInstallGateProvider with a\n'
            'typed InstallCaller (StoreTabInstaller / DetailsModalInstaller\n'
            '/ DeepLinkInstaller / AutoUpdateInstaller / DevBenchInstaller).\n'
            'See lib/features/mini_apps/state/mini_app_install_gate.dart.\n\n'
            'Offenders:\n${offenders.join('\n')}',
      );
    },
  );
}

Future<List<String>> _scan({
  required String projectRoot,
  required Set<String> exemptPaths,
  required RegExp pattern,
}) async {
  final dir = Directory(projectRoot);
  if (!dir.existsSync()) fail('lib/ not found — run from project root');
  final offenders = <String>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;
    // Normalize to forward slashes so the exempt set (`lib/...`) matches
    // on Windows (where Directory.list yields `lib\...`).
    final rel = entity.path
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'^\./'), '');
    if (exemptPaths.contains(rel)) continue;
    final source = await entity.readAsString();
    for (final (i, line) in source.split('\n').indexed) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//') ||
          trimmed.startsWith('///') ||
          trimmed.startsWith('*')) {
        continue;
      }
      if (pattern.hasMatch(line)) {
        offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }
  }
  return offenders;
}
