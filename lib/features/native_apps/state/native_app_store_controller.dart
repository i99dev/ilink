library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_apk_importer.dart';

import '../../../kernel/lifecycle/app_lifecycle_bus.dart';
import '../../app_actions/domain/app_action.dart';
import '../../app_actions/domain/app_target.dart';
import '../../app_actions/state/app_action_controller.dart';
import '../../home/state/installed_apps_provider.dart';
import '../data/native_app_catalog_api.dart';
import '../domain/native_app.dart';

/// Build-time gate for the installed-app catalog and local APK import.
final nativeStoreEnabledProvider = Provider<bool>((_) {
  return const bool.fromEnvironment(
    'APP_NATIVE_STORE_ENABLED',
    defaultValue: true,
  );
});

/// What happened when the user tapped Install/Update on a store row.
enum NativeStoreInstallKind {
  /// Consent installer fired — the system dialog is up; user finishes it.
  installing,

  /// A local file validation or platform error.
  error,

  /// The package was removed.
  uninstalled,

  /// The uninstall shell command failed.
  uninstallFailed,
}

class NativeStoreInstallResult {
  const NativeStoreInstallResult(this.kind, {this.message});
  final NativeStoreInstallKind kind;

  /// Detail for a local file validation or platform error.
  final String? message;
}

final nativeAppStoreProvider =
    AsyncNotifierProvider<NativeAppStoreController, List<NativeApp>>(
      NativeAppStoreController.new,
    );

class NativeAppStoreController extends AsyncNotifier<List<NativeApp>> {
  @override
  Future<List<NativeApp>> build() {
    // When the app foregrounds — notably when the user returns from the
    // system install/consent dialog — cheaply re-read installed versions so
    // the Install button flips to Installed (or Update → Installed) without
    // reopening the screen. No catalog re-fetch; just the pkg.list overlay.
    final sub = ref
        .read(appLifecycleBusProvider)
        .onResumed
        .listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return _load();
  }

  Future<List<NativeApp>> _load() async {
    final api = ref.read(nativeAppCatalogApiProvider);
    final catalog = await api.fetchCatalog();
    final installed = await _installedVersions();
    return [
      for (final app in catalog)
        app.withInstalledVersion(installed[app.packageId]),
    ];
  }

  /// Re-fetch the catalog + installed state. Wired to pull-to-refresh.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// Cheap re-stamp of install state onto the already-loaded catalog — no
  /// network. Used on app-resume so the Install/Update button reflects what
  /// actually got installed after the system consent dialog, with no spinner
  /// and no reopen. No-op until the catalog has loaded.
  Future<void> refreshInstalledState() async {
    final current = state.value;
    if (current == null) return;
    final installed = await _installedVersions();
    final next = [
      for (final app in current)
        app.withInstalledVersion(installed[app.packageId]),
    ];
    // The provider lives for the session (not autoDispose), so this is safe
    // in normal runtime; guard only against a disposed container in tests.
    try {
      state = AsyncData(next);
    } catch (_) {
      /* provider disposed mid-refresh */
    }
  }

  /// packageName → installed versionCode, from `pkg.list` (system apps
  /// included so a system-installed native app is still recognised).
  Future<Map<String, int>> _installedVersions() async {
    final bridge = ref.read(pkgBridgeProvider);
    final pkgs = await bridge.list(includeSystem: true);
    return {for (final p in pkgs) p.packageName: p.versionCode};
  }

  /// Explicitly selected local APK; Android verifies signatures and asks consent.
  Future<NativeStoreInstallResult> importApk(
    String path, {
    String? expectedPackage,
  }) async {
    try {
      await ref
          .read(localApkImporterProvider)
          .install(path, expectedPackage: expectedPackage);
      return const NativeStoreInstallResult(NativeStoreInstallKind.installing);
    } catch (e) {
      return NativeStoreInstallResult(
        NativeStoreInstallKind.error,
        message: '$e',
      );
    }
  }

  /// Uninstall a native app via the shared app-actions path
  /// (`pm uninstall --user 0` through the daemon shell — the same silent
  /// uninstall the home apps grid uses). Refreshes install state on success
  /// so the button flips back to Install. [label] is the resolved display
  /// name (the action layer requires a target label).
  Future<NativeStoreInstallResult> uninstall(
    NativeApp app, {
    required String label,
  }) async {
    final outcome = await ref
        .read(appActionControllerProvider.notifier)
        .run(
          kind: AppActionKind.uninstall,
          target: NativeAppTarget(packageName: app.packageId, label: label),
        );
    if (outcome == AppActionOutcome.ok) {
      await refreshInstalledState();
      return const NativeStoreInstallResult(NativeStoreInstallKind.uninstalled);
    }
    return const NativeStoreInstallResult(
      NativeStoreInstallKind.uninstallFailed,
    );
  }
}
