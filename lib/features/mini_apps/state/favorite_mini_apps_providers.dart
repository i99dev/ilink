import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/favorite_mini_apps_storage.dart';
import '../domain/mini_app.dart';
import 'mini_app_providers.dart';

/// Riverpod surface for the home-strip favourite mini-apps.
///
/// Three layers:
///
///   1. [favoriteMiniAppIdsProvider] — async-loaded ordered id list
///      from [FavoriteMiniAppsStorage]. Source of truth for what the
///      user has marked, regardless of install state.
///
///   2. [favoriteMiniAppsProvider] — derived synchronous view that
///      resolves each id against [installedMiniAppsProvider] and
///      drops anything that doesn't resolve to an installed app, so
///      the home strip never renders a placeholder for an
///      uninstalled / unpublished id.
///
///   3. [isFavoriteMiniAppProvider] — fast per-id boolean for the
///      actions sheet's "Add to favourites" toggle. Built off the
///      raw id list so a long-press on an app the user just
///      uninstalled still reports "favourited", which keeps the
///      mental model simple ("favouriting and installing are
///      independent").
final favoriteMiniAppIdsProvider =
    AsyncNotifierProvider<FavoriteMiniAppIdsController, List<String>>(
      FavoriteMiniAppIdsController.new,
    );

class FavoriteMiniAppIdsController extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final storage = ref.read(favoriteMiniAppsStorageProvider);
    return storage.load();
  }

  /// Append [appId] to the favourites list. No-op if the id is
  /// already present — favouriting is a set, not a multiset.
  Future<void> add(String appId) async {
    final current = state.value ?? const <String>[];
    if (current.contains(appId)) return;
    final next = [...current, appId];
    await _persist(next);
  }

  /// Remove [appId] from the list. No-op when the id isn't there.
  Future<void> remove(String appId) async {
    final current = state.value ?? const <String>[];
    if (!current.contains(appId)) return;
    final next = [
      for (final id in current)
        if (id != appId) id,
    ];
    await _persist(next);
  }

  /// Toggle helper for the actions-sheet entry. Returns the new
  /// favoured-state (true = added).
  Future<bool> toggle(String appId) async {
    final current = state.value ?? const <String>[];
    final wasFavourite = current.contains(appId);
    if (wasFavourite) {
      await remove(appId);
    } else {
      await add(appId);
    }
    return !wasFavourite;
  }

  Future<void> _persist(List<String> next) async {
    state = AsyncData(List.unmodifiable(next));
    await ref.read(favoriteMiniAppsStorageProvider).save(next);
  }
}

/// Resolved favourites: ordered list of [MiniApp] entries the home
/// strip can render directly. Drops ids that the catalog hasn't
/// surfaced as installed yet (uninstalled, unpublished, or still
/// loading) so the strip stays honest about what's launchable.
final favoriteMiniAppsProvider = Provider<List<MiniApp>>((ref) {
  final ids =
      ref.watch(favoriteMiniAppIdsProvider.select((a) => a.value)) ??
      const <String>[];
  if (ids.isEmpty) return const [];
  final installed = ref.watch(installedMiniAppsProvider);
  if (installed.isEmpty) return const [];
  final byId = {for (final app in installed) app.id: app};
  return [
    for (final id in ids)
      if (byId[id] != null) byId[id]!,
  ];
});

/// Per-id boolean for the actions sheet. Reads the raw id list (not
/// the resolved one) so favouriting state is stable across install /
/// uninstall churn.
final isFavoriteMiniAppProvider = Provider.family<bool, String>((ref, appId) {
  final ids =
      ref.watch(favoriteMiniAppIdsProvider.select((a) => a.value)) ??
      const <String>[];
  return ids.contains(appId);
});
