import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mini_app.dart';
import 'mini_app_providers.dart';

/// Caller identity for [MiniAppInstallGate]. Sealed so the audit log and
/// any future scope checks have a closed set of cases. Adding a new
/// caller: extend the sealed class, add a singleton, update
/// `no_direct_catalog_install_test.dart` if its file path is different.
@immutable
sealed class InstallCaller {
  const InstallCaller();

  /// Stable lowercase snake_case label used in logs / metrics. Must
  /// match the regex `[a-z][a-z0-9_]*` so log aggregators don't have
  /// to quote-escape it.
  String get kindLabel;
}

/// User tapped Install/Uninstall on a Store-tab card or list row.
class StoreTabInstaller extends InstallCaller {
  const StoreTabInstaller._();
  static const StoreTabInstaller instance = StoreTabInstaller._();
  @override
  String get kindLabel => 'store_tab';
}

/// User tapped Install/Uninstall inside the tap-to-details modal.
class DetailsModalInstaller extends InstallCaller {
  const DetailsModalInstaller._();
  static const DetailsModalInstaller instance = DetailsModalInstaller._();
  @override
  String get kindLabel => 'details_modal';
}

/// Mini-app deep link landed; the link payload requested an install.
class DeepLinkInstaller extends InstallCaller {
  const DeepLinkInstaller._();
  static const DeepLinkInstaller instance = DeepLinkInstaller._();
  @override
  String get kindLabel => 'deep_link';
}

/// Auto-update path — installed bundle SHA differs from the catalog
/// SHA at launch and the user accepted the update sheet (or it ran
/// silently for production-track apps).
class AutoUpdateInstaller extends InstallCaller {
  const AutoUpdateInstaller._();
  static const AutoUpdateInstaller instance = AutoUpdateInstaller._();
  @override
  String get kindLabel => 'auto_update';
}

/// Dev-test-bench install button (only reachable when
/// `devCarControlsEnabled` is on).
class DevBenchInstaller extends InstallCaller {
  const DevBenchInstaller._();
  static const DevBenchInstaller instance = DevBenchInstaller._();
  @override
  String get kindLabel => 'dev_bench';
}

/// Outcome of an [MiniAppInstallGate.install] / `.uninstall` call.
/// Sealed — every code path consumes a closed set, and the snackbar
/// renderer in `install_feedback.dart` switches on the variant to
/// produce localized copy.
@immutable
sealed class InstallOutcome {
  const InstallOutcome();
}

/// Install / uninstall succeeded.
class InstallOk extends InstallOutcome {
  const InstallOk();
}

/// Caller asked for an app id that isn't in the current catalog
/// snapshot. Either the catalog hasn't loaded, or the row was delisted
/// between the user's tap and our resolution.
class InstallUnknownApp extends InstallOutcome {
  const InstallUnknownApp(this.appId);
  final String appId;
}

/// Underlying install / uninstall threw. Wraps the raw exception so the
/// caller can hand it to `showInstallErrorSnack` for the same friendly
/// translation `_InstallButton` used to do inline.
class InstallFailed extends InstallOutcome {
  const InstallFailed(this.error);
  final Object error;
}

class MiniAppInstallGate {
  MiniAppInstallGate(this._ref);

  final Ref _ref;

  /// Install [appId] on behalf of [caller]. Routes the call through the
  /// catalog notifier (which already branches on `app.privileged` to
  /// dispatch the correct path — privileged orchestrator vs the regular
  /// bundle store). The pre-checks here are the *only* thing that
  /// changes between callers; the install pipeline downstream is
  /// identical.
  Future<InstallOutcome> install({
    required InstallCaller caller,
    required String appId,
  }) async {
    final app = _resolve(appId);
    if (app == null) return InstallUnknownApp(appId);

    try {
      await _ref.read(miniAppCatalogProvider.notifier).install(appId);
      return const InstallOk();
    } catch (e) {
      return InstallFailed(e);
    }
  }

  /// Uninstall [appId] on behalf of [caller]. No track-aware checks —
  /// uninstall is always permissible (unlike install, which gates on
  /// tester roster for the beta track).
  Future<InstallOutcome> uninstall({
    required InstallCaller caller,
    required String appId,
  }) async {
    try {
      await _ref.read(miniAppCatalogProvider.notifier).uninstall(appId);
      return const InstallOk();
    } catch (e) {
      return InstallFailed(e);
    }
  }

  /// Re-install [appId] over an existing install — used by the
  /// auto-update path when the catalog SHA diverges from the recorded
  /// SHA. Same gate semantics as [install] (beta-track requires login,
  /// privileged routes through the orchestrator); only the underlying
  /// notifier method differs.
  Future<InstallOutcome> reinstall({
    required InstallCaller caller,
    required String appId,
  }) async {
    final app = _resolve(appId);
    if (app == null) return InstallUnknownApp(appId);

    try {
      await _ref.read(miniAppCatalogProvider.notifier).reinstall(appId);
      return const InstallOk();
    } catch (e) {
      return InstallFailed(e);
    }
  }

  MiniApp? _resolve(String appId) {
    final catalog = _ref.read(miniAppCatalogProvider).value;
    if (catalog == null) return null;
    for (final app in catalog) {
      if (app.id == appId) return app;
    }
    return null;
  }
}

/// Riverpod handle for [MiniAppInstallGate]. Held as a `Provider`
/// because the gate is a stateless façade over the catalog notifier
/// (Riverpod owns the [Ref]).
final miniAppInstallGateProvider = Provider<MiniAppInstallGate>((ref) {
  return MiniAppInstallGate(ref);
});
