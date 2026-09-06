import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/car/client.dart' show carClientProvider;
import '../../../sdk/car/providers.dart' show daemonReadyProvider;
import '../../home/state/installed_apps_provider.dart'
    show installedAppsProvider, pkgBridgeProvider;
import '../domain/quick_fix_action.dart';

/// Stable action ids — keyed by the controller, asserted by tests.
const String kCloseAppsActionId = 'close_other_apps';
const String kClearClusterActionId = 'clear_cluster';
const String kWakeDaemonActionId = 'wake_daemon';

/// The host package — never force-stopped by the "close other apps" tool.
const String kHostPackage = 'com.i99dev.ilink';

/// **Single source of truth for the Doctor sheet's quick-fix actions.**
///
/// Adding a tool = one row here (id + icon + two l10n keys + a
/// context-free `run`). The sheet iterates this list; nothing references
/// an action by identity except its stable [QuickFixAction.id].
const List<QuickFixAction> kQuickFixActions = <QuickFixAction>[
  QuickFixAction(
    id: kCloseAppsActionId,
    icon: Icons.layers_clear_rounded,
    labelKey: 'doctorCloseAppsLabel',
    whyKey: 'doctorCloseAppsWhy',
    run: closeOtherApps,
  ),
  QuickFixAction(
    id: kClearClusterActionId,
    icon: Icons.cleaning_services_rounded,
    labelKey: 'doctorClearClusterLabel',
    whyKey: 'doctorClearClusterWhy',
    run: clearCluster,
  ),
  QuickFixAction(
    id: kWakeDaemonActionId,
    icon: Icons.sensors_rounded,
    labelKey: 'doctorWakeDaemonLabel',
    whyKey: 'doctorWakeDaemonWhy',
    run: wakeDaemon,
  ),
];

/// Force-stop every **user** app except the host. We intersect the
/// running tasks with the non-system installed list (which already
/// excludes the host), so the launcher / SystemUI / BYD home are never
/// killed — closing those would brick the car UI. Returns the count of
/// apps actually stopped.
Future<QuickFixResult> closeOtherApps(Ref ref) async {
  final bridge = ref.read(pkgBridgeProvider);
  final installed = await ref.read(installedAppsProvider.future);
  final userPkgs = {for (final p in installed) p.packageName};
  final running = await bridge.running();
  final targets = <String>{
    for (final t in running)
      if (t.packageName != kHostPackage && userPkgs.contains(t.packageName))
        t.packageName,
  };
  if (targets.isEmpty) return const QuickFixResult.ok(0);
  // Bridge calls are off-UI MethodChannel work — stop concurrently.
  final results = await Future.wait(
    targets.map((p) => bridge.stop(packageName: p)),
  );
  final closed = results.where((r) => r.ok).length;
  // The home running-apps strip re-polls every ~2s, so the chips for the
  // stopped apps clear on their own — no manual refresh dependency here
  // (keeps this action pure + unit-testable).
  return QuickFixResult.ok(closed);
}

/// Clear leftover/frozen apps from the instrument-cluster display — the
/// exact `clusterClear` primitive the cluster touchpad sheet uses.
Future<QuickFixResult> clearCluster(Ref ref) async {
  final ok = await ref.read(pkgBridgeProvider).clusterClear();
  return ok ? const QuickFixResult.ok() : const QuickFixResult.failed();
}

/// Wake the car-control daemon so voice car-actions resolve. Triggers the
/// same warm/seed the boot path runs (`liveFeatures()` → establishes the
/// daemon connection + seeds the dashboard set), re-polls the readiness
/// stream, then confirms via a fresh `daemonStatus()`.
Future<QuickFixResult> wakeDaemon(Ref ref) async {
  final client = ref.read(carClientProvider);
  try {
    await client.liveFeatures();
  } catch (_) {
    // Fall through — the status check below is the source of truth.
  }
  ref.invalidate(daemonReadyProvider);
  try {
    final status = await client.daemonStatus();
    return status['daemon'] == true
        ? const QuickFixResult.ok()
        : const QuickFixResult.failed();
  } catch (_) {
    return const QuickFixResult.failed();
  }
}
