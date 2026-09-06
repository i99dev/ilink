import 'package:dio/dio.dart';

import '../domain/theme_item.dart';
import 'built_in_themes.dart';

/// Boundary the state layer talks to for the **theme catalog**. Only
/// the catalog lives here — the active-theme selection is local-only
/// (`AppSettings.activeThemeId`). Mirrors [MiniAppRepository]: the
/// backend owns "what themes exist", the head-unit owns "which one is
/// applied".
///
/// Every implementation returns the built-in themes first (so a fresh /
/// offline car always has a working picker) followed by whatever the
/// remote catalog adds. Built-ins carry `isBuiltIn: true`; remote rows
/// carry `false`.
abstract class ThemeRepository {
  const ThemeRepository();

  /// Fetches the full catalog (built-ins + remote). Rows are emitted
  /// with `isActive: false` — the state layer stamps the active flag
  /// from `AppSettings.activeThemeId` before the UI sees them.
  Future<List<ThemeItem>> fetchCatalog({required CancelToken cancelToken});

  /// Last cached catalog for instant render, or null when there is no
  /// cache (or this impl doesn't persist). Built-ins are always
  /// available even when this returns null — the caller folds them in.
  Future<List<ThemeItem>?> readCachedCatalog() async => null;
}

/// Offline / default repository: returns only the bundled built-in
/// themes. Used when the themes backend isn't wired (compile-time
/// switch), and as the floor every other implementation builds on.
class BuiltInThemeRepository extends ThemeRepository {
  const BuiltInThemeRepository();

  @override
  Future<List<ThemeItem>> fetchCatalog({
    required CancelToken cancelToken,
  }) async => kBuiltInThemes;

  @override
  Future<List<ThemeItem>?> readCachedCatalog() async => kBuiltInThemes;
}
