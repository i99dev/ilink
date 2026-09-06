/// Helper for "Open on N display" actions surfaced from the mini-app
/// launcher's long-press sheet.
///
/// Routes through the same [FamilyExecutor] the mini-app's WebView
/// uses for `surface.create`, so the manifest-backed consent gate
/// applies identically. The user gets one signed audit-chain entry
/// matching the bundle they launched, even when the launch came from
/// the IVI's launcher rather than from inside another mini-app.
///
/// Reuses, does not rebuild:
///   * [familyExecutorProvider] — same executor + gate as the
///     in-WebView path.
///   * [SurfaceFamily.create] — host-side `Presentation`/overlay/
///     am-start mount, identical to bridge-driven calls.
///   * `localProfileProvider` + `currentCarProvider` — same session shape.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_mini_apps/domain/admin_dispatcher.dart';
import '../../profile/state/local_profile_provider.dart';
import '../data/mini_app_install_storage.dart';
import '../domain/mini_app.dart';
import 'family_executor_provider.dart';

/// Open [app] on display [displayId] via the surface family. Returns
/// the `surface.create` envelope on success, an [AdminExecError] on
/// failure. Caller is responsible for showing UI feedback (snackbar
/// / toast); this function performs no UI side effects so it stays
/// testable.
///
/// Typical usage from a tap handler:
///
///     final r = await openMiniAppOnDisplay(ref, app, displayId: 2);
///     if (r is AdminExecError) {
///       ScaffoldMessenger.of(ctx).showSnackBar(
///         SnackBar(content: Text('Failed: ${r.code}')),
///       );
///     } else {
///       ScaffoldMessenger.of(ctx).showSnackBar(
///         const SnackBar(content: Text('Opened on passenger screen')),
///       );
///     }
Future<Object> openMiniAppOnDisplay(
  WidgetRef ref,
  MiniApp app, {
  required int displayId,
  String route = '/',
}) async {
  final account = ref.read(localProfileProvider).value;
  final car = ref.read(currentCarProvider);
  final certHash =
      app.certHash ??
      await ref.read(miniAppInstallStorageProvider).certHashFor(app.id) ??
      '';
  final session = AdminSession(
    userId: account?.id ?? '',
    deviceId: car?.deviceId ?? '',
    appId: app.id,
    certHash: certHash,
    bundleSha256: app.bundleSha256,
  );
  final exec = await ref.read(familyExecutorProvider.future);
  return exec.execute(
    familyId: 'surface',
    op: 'create',
    args: <String, Object?>{'displayId': displayId, 'route': route},
    session: session,
  );
}
