/// Riverpod wiring for the cold-start `boot.write` replay.
///
/// One [FutureProvider<void>] that the widget tree watches once,
/// near the root, after authentication has resolved. Reads the
/// active (userId, deviceId), opens the admin DB, and asks
/// [BootLauncher.runIfFreshBoot] whether this is a fresh boot —
/// if so, every persisted boot.write row gets replayed against
/// pkg.launch, deduped by `(packageName, displayId)`.
///
/// The provider returns void; the per-row replay outcomes are
/// only logged. Consumers `.when` on the future to render an
/// optional spinner during a long replay (rare — most replays
/// fire 0-2 launches and finish in under 200 ms).
library;

import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import '../../admin_mini_apps/state/admin_dispatcher_provider.dart';
import '../packaging/pkg_native_bridge.dart';
import 'boot_launcher.dart';
import 'boot_native_bridge.dart';
import 'boot_store.dart';

void _log(String msg) => developer.log(msg, name: 'boot_launcher_provider');

/// Result surface for the cold-start replay. Cold-start callers
/// (the home pane) read this to surface a one-time toast when at
/// least one boot.write row didn't replay cleanly. Empty list =
/// nothing to show.
class BootReplaySummary {
  const BootReplaySummary({required this.failures});

  /// Per-row outcomes that came back as `ok=false`. Includes the
  /// failing [BootEntry] so the toast can name the package.
  final List<BootReplayResult> failures;

  bool get hasFailures => failures.isNotEmpty;

  static const empty = BootReplaySummary(failures: <BootReplayResult>[]);
}

/// Single-shot per app session. Watch this once at the top of the
/// widget tree (alongside [bootWipeResumeProvider]) to fire the
/// replay after auth + settings resolve.
///
/// Returns a [BootReplaySummary] (instead of `void`) so the home
/// pane can surface a "boot replay had failures" toast without
/// re-running the replay. The provider does NOT auto-retry —
/// per-row retry is handled inside [BootLauncher._replayOne] for
/// the specific BYD WMS transient case; broader retry would risk
/// duplicate launches across reboots.
final bootReplayProvider = FutureProvider<BootReplaySummary>((ref) async {
  final db = await ref.watch(adminDatabaseProvider.future);
  final settings = await ref.watch(settingsProvider.future);
  final userId = settings.userId;
  final deviceId = settings.deviceId;
  if (userId.isEmpty || deviceId.isEmpty) {
    _log('skipping boot replay — userId or deviceId empty');
    return BootReplaySummary.empty;
  }

  final launcher = BootLauncher(
    store: BootStore(db),
    pkgBridge: PlatformPkgNativeBridge(),
    bootBridge: PlatformBootNativeBridge(),
  );

  try {
    final results = await launcher.runIfFreshBoot(
      userId: userId,
      deviceId: deviceId,
    );
    if (results.isEmpty) return BootReplaySummary.empty;
    final failures = results.where((r) => !r.ok).toList(growable: false);
    final ok = results.length - failures.length;
    _log(
      'boot replay fired ${results.length} row(s) — '
      '$ok ok, ${failures.length} failed',
    );
    return BootReplaySummary(failures: failures);
  } catch (e) {
    // Don't propagate — a failing replay shouldn't block the rest
    // of the host. Boot launches are best-effort.
    _log('boot replay threw: $e');
    return BootReplaySummary.empty;
  }
});
