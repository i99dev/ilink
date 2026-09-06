import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/api/cancellation.dart';
import '../data/installed_mini_app_store.dart';
import '../data/mini_app_install_storage.dart'
    show InstalledMiniAppRecord, miniAppInstallStorageProvider;
import '../domain/mini_app.dart';
import 'mini_app_repository_provider.dart';

/// Catalog + install-state controller. Owns the merge of "what the
/// backend says exists" and "what this user has pinned locally", and
/// is the sole write path for install / uninstall so the UI never
/// touches [MiniAppInstallStorage] directly.
///
/// Why an [AsyncNotifier] over two derived providers:
///   - The catalog fetch is async and can fail; an AsyncNotifier gives
///     us AsyncValue for free (loading / error / data) so the Store
///     screen renders the right surface without hand-rolled state.
///   - Install / uninstall mutate the same list — putting them on the
///     notifier keeps the storage-write + state-patch transaction in
///     one place (matches how [LocalProfileController.signOut] collocates
///     backend + local-clear).
class MiniAppCatalogController extends AsyncNotifier<List<MiniApp>> {
  /// Shared across every repository call this controller makes. Cancels
  /// when the provider disposes so a rebuild-mid-fetch doesn't complete
  /// into a torn-down state machine — same pattern as AuthController /
  /// LocalProfileController.
  late final CancelToken _lifetimeCancel = ref.cancelOnDispose(
    reason: 'mini-app catalog provider rebuilt',
  );

  /// Wall-clock timestamp of the last successful catalog fetch. Drives
  /// the stale-catalog banner on the Store tab — when this is older than
  /// the staleness threshold, the UI prompts the tester to pull-refresh.
  /// Null until the first fetch lands; updated on every successful
  /// `_fetchAndMerge` and `_revalidate` call.
  DateTime? lastFetchAt;

  @override
  Future<List<MiniApp>> build() async {
    // Stale-while-revalidate: if the API repository has a cached
    // catalog, render it immediately (zero perceived latency on warm
    // launches and offline) and revalidate against the network in
    // the background. The revalidation result lands via [state] —
    // the user sees an in-place update with no spinner flash.
    final repo = ref.read(miniAppRepositoryProvider);
    final cached = await repo.readCachedCatalog();
    if (cached != null) {
      // Schedule the network refresh; don't await it from build()
      // — that would defeat the instant-render win. Errors during
      // revalidation also don't surface as AsyncError, since we
      // already have a known-good cached state.
      // ignore: unawaited_futures
      Future.microtask(_revalidate);
      final installed = await ref.read(miniAppInstallStorageProvider).load();
      return _mergeInstallState(cached, installed);
    }
    return _fetchAndMerge();
  }

  /// Pull-to-refresh entry point. Stays on the current data while the
  /// network round-trip runs (no [AsyncLoading] flash); the
  /// RefreshIndicator owns the spinner. Same merge logic as
  /// [build] / [_fetchAndMerge].
  Future<void> refresh() async {
    final next = await AsyncValue.guard(_fetchAndMerge);
    state = next;
  }

  /// Background revalidation kicked off from [build] when we rendered
  /// from cache. A failure here is silent — the user is already seeing
  /// the last-known catalog and can pull to retry.
  ///
  /// Crucially: the revalidate refreshes the *catalog content* (icons,
  /// names, urls — anything the backend owns) but preserves the
  /// *install state* from in-memory. If the user tapped Install while
  /// our HTTP fetch was in flight, their write to SharedPreferences may
  /// still be in flight when we arrive here; re-reading storage at
  /// this point would race the write and silently revert the user's
  /// click. Treating in-memory install state as truth (with
  /// install/uninstall already having patched it) closes that gap —
  /// SharedPreferences stays authoritative on next cold start.
  Future<void> _revalidate() async {
    try {
      final repo = ref.read(miniAppRepositoryProvider);
      final catalog = await repo.fetchCatalog(cancelToken: _lifetimeCancel);
      final current = state.value;
      // Treat in-memory install state as truth (see method docstring
      // for the race the original used to hit). Carry the cert hash
      // along so a privileged install that completed between the
      // initial render and this revalidate doesn't lose its binding.
      final installed = <String, InstalledMiniAppRecord>{
        if (current != null)
          for (final a in current)
            if (a.isInstalled && a.installedAt != null)
              a.id: InstalledMiniAppRecord(
                installedAt: a.installedAt!,
                certHash: a.certHash,
              ),
      };
      state = AsyncData(_mergeInstallState(catalog, installed));
      lastFetchAt = DateTime.now();
    } catch (_) {
      // Keep the cached state. The API repository already
      // gracefully degrades to its own cache on transport errors,
      // so reaching this branch implies a parse / merge bug we
      // shouldn't paper over with an error banner.
    }
  }

  /// Pin a mini-app to "My Apps". Branches on [MiniApp.privileged]:
  ///
  /// * **Non-privileged (default):**
  ///     1. Download + extract via [InstalledMiniAppStore].
  ///     2. Stamp SharedPreferences + in-memory state.
  ///
  /// * **Privileged (`_admin.exec` consumer):**
  ///     1. Run the full [PrivilegedInstallOrchestrator] pipeline —
  ///        manifest fetch → cert verify → bundle install → session
  ///        cap fetch + verify → catalog refresh → cert hash stamp.
  ///        Each failure mode (cert mismatch, cap invalid, network)
  ///        propagates as a typed `PrivilegedInstallException` for the
  ///        UI to render localized copy.
  ///     2. Patch in-memory state with the verified cert hash so the
  ///        WebView's `_admin.exec` handler can build a real
  ///        `AdminSession` immediately on first launch.
  ///
  /// Order matters either way: do the slow + fallible work first,
  /// only then commit local state. If we patched the in-memory state
  /// up front and the download failed, the UI would briefly lie
  /// before the catch-block reconciled — bad UX on a slow head-unit
  /// network. The Install button itself shows progress via the
  /// controller's AsyncValue while this future runs.
  Future<void> install(String id) async {
    final current = state.value;
    if (current == null) return;
    final app = current.firstWhere(
      (a) => a.id == id,
      orElse: () =>
          throw StateError('install($id): app not in current catalog'),
    );

    if (app.privileged) {
      throw StateError(
        'Legacy signed extensions require review and cannot be installed in the standalone app.',
      );
    }

    // Non-privileged (regular) path — unchanged from before.
    final store = ref.read(installedMiniAppStoreProvider);
    // Suspend grants while installed files are being replaced.
    await ref.read(miniAppInstallStorageProvider).updateBundleSha(app.id, null);
    await store.install(app, cancelToken: _lifetimeCancel);

    // Persist the install metadata only after the bytes are on disk.
    // bundleSha256 is recorded so launch-time auto-update can detect a
    // developer's `sdk beta promote` rolling out (catalog SHA diverges
    // from the recorded SHA → prompt update).
    final installStorage = ref.read(miniAppInstallStorageProvider);
    try {
      await installStorage.install(id, bundleSha256: app.bundleSha256);
      await installStorage.updateBundleSha(id, app.bundleSha256);
    } catch (_) {
      // Local SharedPreferences write failed, but the bundle is
      // already extracted. Roll back the on-disk install so we
      // don't end up with bytes on disk that nothing knows about.
      await store.uninstall(id);
      rethrow;
    }
    _patch(id, isInstalled: true, installedAt: DateTime.now());
  }

  /// Re-install [id] over an existing install, updating both the bundle
  /// bytes on disk AND the recorded SHA. Used by the auto-update path
  /// when the catalog SHA diverges from the installed SHA. Idempotent:
  /// if the disk re-extract throws, the storage record stays untouched
  /// so a retry sees the same "stale" state and can prompt again.
  Future<void> reinstall(String id) async {
    final current = state.value;
    if (current == null) return;
    final app = current.firstWhere(
      (a) => a.id == id,
      orElse: () =>
          throw StateError('reinstall($id): app not in current catalog'),
    );
    if (app.privileged) {
      throw StateError(
        'Legacy signed extensions require review and cannot be installed in the standalone app.',
      );
    }
    final store = ref.read(installedMiniAppStoreProvider);
    // Suspend grants while installed files are being replaced.
    await ref.read(miniAppInstallStorageProvider).updateBundleSha(app.id, null);
    await store.install(app, cancelToken: _lifetimeCancel);
    await ref
        .read(miniAppInstallStorageProvider)
        .updateBundleSha(id, app.bundleSha256);
    _patch(id, isInstalled: true, installedAt: DateTime.now());
  }

  Future<void> uninstall(String id) async {
    // Optimistic UI flip — uninstall is fast and local; if the
    // storage write fails we reconcile.
    _patch(id, isInstalled: false, installedAt: null);
    try {
      await ref.read(miniAppInstallStorageProvider).uninstall(id);
      await ref.read(installedMiniAppStoreProvider).uninstall(id);
    } catch (_) {
      await _reconcileFromStorage();
      rethrow;
    }
  }

  /// Replace the install-state fields of the single row with [id]
  /// inside the current AsyncData list. No-op if the state isn't
  /// AsyncData yet (catalog still loading or errored) — the Store
  /// screen hides install affordances in those states anyway.
  ///
  /// [certHash] is forwarded for privileged installs so the WebView's
  /// `_admin.exec` handler doesn't need a second storage lookup.
  void _patch(
    String id, {
    required bool isInstalled,
    required DateTime? installedAt,
    String? certHash,
  }) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final app in current)
        if (app.id == id)
          app.withInstallState(
            isInstalled: isInstalled,
            installedAt: installedAt,
            certHash: certHash,
          )
        else
          app,
    ]);
  }

  /// On a storage write failure, re-read storage and reapply onto the
  /// current catalog so the UI reflects truth instead of the optimistic
  /// assumption. Preserves the catalog fetch — only the install fields
  /// are recomputed.
  Future<void> _reconcileFromStorage() async {
    final current = state.value;
    if (current == null) return;
    final installed = await ref.read(miniAppInstallStorageProvider).load();
    state = AsyncData(_mergeInstallState(current, installed));
  }

  Future<List<MiniApp>> _fetchAndMerge() async {
    final repo = ref.read(miniAppRepositoryProvider);
    final catalog = await repo.fetchCatalog(cancelToken: _lifetimeCancel);
    final installed = await ref.read(miniAppInstallStorageProvider).load();
    final merged = _mergeInstallState(catalog, installed);
    lastFetchAt = DateTime.now();
    return merged;
  }

  /// Fold storage records onto freshly-fetched catalog rows. Orphaned
  /// install ids (in storage but no longer in the catalog) are
  /// silently skipped; they're still present in storage so they
  /// reappear if the catalog re-lists them later.
  ///
  /// `certHash` from each storage record propagates onto the rendered
  /// `MiniApp` so the WebView's `_admin.exec` handler can read it
  /// without a second storage round-trip.
  static List<MiniApp> _mergeInstallState(
    List<MiniApp> catalog,
    Map<String, InstalledMiniAppRecord> installed,
  ) {
    return [
      for (final app in catalog)
        app.withInstallState(
          isInstalled: installed.containsKey(app.id),
          installedAt: installed[app.id]?.installedAt,
          certHash: installed[app.id]?.certHash,
        ),
    ];
  }
}

final miniAppCatalogProvider =
    AsyncNotifierProvider<MiniAppCatalogController, List<MiniApp>>(
      MiniAppCatalogController.new,
    );

/// Derived: the subset the "My Apps" surface renders. Returns an empty
/// list while the catalog is loading or errored — callers that want to
/// distinguish those states should watch [miniAppCatalogProvider]
/// directly.
final installedMiniAppsProvider = Provider<List<MiniApp>>((ref) {
  final catalog = ref.watch(miniAppCatalogProvider).value;
  if (catalog == null) return const [];
  return [
    for (final app in catalog)
      if (app.isInstalled) app,
  ];
});

/// Derived: catalog rows in catalog order — backend already orders by
/// editorial preference, so the host preserves that ordering verbatim.
final orderedMiniAppCatalogProvider = Provider<List<MiniApp>>((ref) {
  final catalog = ref.watch(miniAppCatalogProvider).value;
  if (catalog == null) return const [];
  return List<MiniApp>.unmodifiable(catalog);
});
