import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/api/cancellation.dart';
import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/ui/theme/app_theme.dart';
import '../../../kernel/ui/theme/theme_spec.dart';
import '../data/built_in_themes.dart';
import '../domain/theme_item.dart';
import 'theme_repository_provider.dart';

/// Theme catalog controller. Owns the merge of "what themes exist"
/// (built-ins + remote) and "which one is active"
/// (`AppSettings.activeThemeId`). Stale-while-revalidate, mirroring
/// [MiniAppCatalogController]: a warm/offline launch renders the cached
/// rows instantly, then revalidates against the network in the
/// background. Built-ins are always present (the repository floors the
/// list with them) so the gallery works on a fresh / offline car.
class ThemeCatalogController extends AsyncNotifier<List<ThemeItem>> {
  late final CancelToken _lifetimeCancel = ref.cancelOnDispose(
    reason: 'theme catalog provider rebuilt',
  );

  @override
  Future<List<ThemeItem>> build() async {
    // Keep the active flag live: re-stamp when the active id changes so
    // the gallery's "active" mark follows an Apply without a refetch.
    final activeId = ref.watch(
      settingsProvider.select((a) => a.value?.activeThemeId ?? ''),
    );
    final repo = ref.read(themeRepositoryProvider);
    final cached = await repo.readCachedCatalog();
    if (cached != null) {
      // ignore: unawaited_futures
      Future.microtask(_revalidate);
      return _stampActive(cached, activeId);
    }
    final fetched = await repo.fetchCatalog(cancelToken: _lifetimeCancel);
    return _stampActive(fetched, activeId);
  }

  /// Pull-to-refresh entry point. Stays on current data while the
  /// round-trip runs (no AsyncLoading flash).
  Future<void> refresh() async {
    final next = await AsyncValue.guard(() async {
      final repo = ref.read(themeRepositoryProvider);
      final fetched = await repo.fetchCatalog(cancelToken: _lifetimeCancel);
      return _stampActive(fetched, _activeId());
    });
    state = next;
  }

  Future<void> _revalidate() async {
    try {
      final repo = ref.read(themeRepositoryProvider);
      final catalog = await repo.fetchCatalog(cancelToken: _lifetimeCancel);
      state = AsyncData(_stampActive(catalog, _activeId()));
    } catch (_) {
      // Keep cached state — the repository already degrades to its own
      // cache (then built-ins) on transport errors.
    }
  }

  String _activeId() => ref.read(settingsProvider).value?.activeThemeId ?? '';

  static List<ThemeItem> _stampActive(List<ThemeItem> rows, String activeId) {
    // Empty activeId = the built-in default (Midnight). Mark it active
    // so the gallery shows a check on the default even before the user
    // ever picks a theme.
    final effective = activeId.isEmpty ? kMidnightThemeId : activeId;
    return [for (final t in rows) t.withState(isActive: t.id == effective)];
  }
}

final themeCatalogProvider =
    AsyncNotifierProvider<ThemeCatalogController, List<ThemeItem>>(
      ThemeCatalogController.new,
    );

/// The active [ThemeSpec], resolved from `AppSettings.activeThemeId`.
///
/// Resolution order, all synchronous so it never blocks first paint:
///   1. empty id → null (caller uses the built-in default light/dark
///      pair — i.e. the historical look; the feature stays inert).
///   2. a built-in id → its const spec (no catalog dependency).
///   3. a catalog id → the spec from the loaded catalog, if present;
///      otherwise null (fall back to built-in default until the
///      catalog lands, then this re-resolves).
///
/// Returns null for "use the built-in default" so `_AppShell` keeps its
/// existing `AppTheme.light()/dark()` wiring untouched in the common
/// case.
final activeThemeSpecProvider = Provider<ThemeSpec?>((ref) {
  final activeId = ref.watch(
    settingsProvider.select((a) => a.value?.activeThemeId ?? ''),
  );
  if (activeId.isEmpty) return null;
  // Built-ins resolve without the catalog so a selected built-in
  // applies instantly on cold boot.
  for (final t in kBuiltInThemes) {
    if (t.id == activeId) return t.spec;
  }
  // Catalog theme: look it up in the loaded catalog. Use .value so we
  // don't await — until the catalog lands we return null (built-in
  // default), then re-resolve when it arrives.
  final catalog = ref.watch(themeCatalogProvider).value;
  if (catalog != null) {
    for (final t in catalog) {
      if (t.id == activeId) return t.spec;
    }
  }
  return null;
});

/// Resolved light + dark [ThemeData] for `MaterialApp`, plus an optional
/// forced [mode].
///
///   * **No theme selected** ([mode] == null) → built-in
///     `AppTheme.light()/dark()`, byte-identical to the historical look,
///     governed by the user's `MaterialApp.themeMode`. The feature is
///     fully inert.
///   * **A theme is selected** → the theme **fully takes over**: the
///     themed [ThemeData] fills BOTH slots and [mode] pins the app to the
///     theme's own brightness. So a theme applies immediately and
///     completely regardless of the prior System/Light/Dark setting —
///     picking "Daylight" lights up a car that was in dark mode, picking
///     "Neon" re-skins it whatever the toggle said. This is the
///     "what you pick is what you see" model a theme store needs.
class ResolvedTheme {
  const ResolvedTheme({required this.light, required this.dark, this.mode});
  final ThemeData light;
  final ThemeData dark;

  /// Non-null when a theme is active and owns the brightness; `_AppShell`
  /// uses `mode ?? userThemeMode`.
  final ThemeMode? mode;
}

final activeThemeDataProvider = Provider.family<ResolvedTheme, String>((
  ref,
  languageCode,
) {
  final spec = ref.watch(activeThemeSpecProvider);
  if (spec == null) {
    return ResolvedTheme(
      light: AppTheme.light(languageCode: languageCode),
      dark: AppTheme.dark(languageCode: languageCode),
    );
  }
  final themed = AppTheme.fromSpec(spec, languageCode: languageCode);
  return ResolvedTheme(
    light: themed,
    dark: themed,
    mode: spec.brightness == ThemeBrightness.light
        ? ThemeMode.light
        : ThemeMode.dark,
  );
});
