import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/kernel/services/optional_services.dart';
import 'package:ilink/features/mini_apps/state/mini_app_providers.dart';
import 'package:ilink/features/themes/state/theme_providers.dart';
import 'package:ilink/kernel/logging/logger.dart';

/// One catalog preparation step: a stable [id], whether it's [required]
/// (informational — every step is fail-open today), and the work.
typedef BootstrapStep = ({
  String id,
  bool required,
  Future<void> Function() run,
});

/// Outcome of a [SessionBootstrap.run]: per-step `null` (ok) or the error.
class SessionSyncReport {
  const SessionSyncReport(this.outcomes);
  final Map<String, Object?> outcomes;

  bool get allOk => outcomes.values.every((e) => e == null);
  Iterable<String> get failed =>
      outcomes.entries.where((e) => e.value != null).map((e) => e.key);
}

/// Runs independent catalog preparation steps without blocking startup.
class SessionBootstrap {
  SessionBootstrap(this._steps);

  final List<BootstrapStep> _steps;
  static const _log = Logger('SessionBootstrap');

  Future<SessionSyncReport> run() async {
    final outcomes = <String, Object?>{};
    for (final step in _steps) {
      try {
        await step.run();
        outcomes[step.id] = null;
      } catch (e) {
        // Fail-open: record + keep going. A flaky catalog warm must not
        // stop the table sync (or vice-versa).
        outcomes[step.id] = e;
        _log.w('session bootstrap step "${step.id}" failed (fail-open): $e');
      }
    }
    if (!outcomes.values.every((e) => e == null)) {
      _log.w(
        'session bootstrap finished with failures: '
        '${outcomes.entries.where((e) => e.value != null).map((e) => e.key).join(", ")}',
      );
    }
    return SessionSyncReport(outcomes);
  }
}

/// Optional catalog preparation.
final sessionBootstrapProvider = Provider<SessionBootstrap>((ref) {
  if (!ref.watch(serviceEnabledProvider(OptionalService.downloads))) {
    return SessionBootstrap([]);
  }
  return SessionBootstrap([
    // Pre-warm the catalogs so Store / Themes are ready when opened
    // (otherwise they lazy-load on first tab open).
    (
      id: 'mini_app_catalog',
      required: false,
      run: () async {
        await ref.read(miniAppCatalogProvider.future);
      },
    ),
    (
      id: 'theme_catalog',
      required: false,
      run: () async {
        await ref.read(themeCatalogProvider.future);
      },
    ),
  ]);
});

/// Warm optional local catalogs after the driver enables downloads.
final sessionBootstrapTriggerProvider = Provider<void>((ref) {
  if (ref.watch(serviceEnabledProvider(OptionalService.downloads))) {
    unawaited(ref.read(sessionBootstrapProvider).run());
  }
});
