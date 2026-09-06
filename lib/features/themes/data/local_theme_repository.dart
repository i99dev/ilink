import 'package:dio/dio.dart';
import '../domain/theme_item.dart';
import 'built_in_themes.dart';
import 'theme_catalog_cache_storage.dart';
import 'theme_catalog_endpoint.dart';
import 'theme_repository.dart';

/// Bundled palettes plus saved theme specifications, evaluated on-device.
class LocalThemeRepository extends ThemeRepository {
  LocalThemeRepository(this.cache, {required this.activeId});
  final ThemeCatalogCacheStorage cache;
  final String activeId;
  @override
  Future<List<ThemeItem>?> readCachedCatalog() async {
    final rows = {for (final t in kBuiltInThemes) t.id: t};
    for (final endpoint in ThemeCatalogEndpoint.values) {
      final saved = await cache.read(endpoint: endpoint);
      for (final row in saved?.rawThemes ?? <Map<String, dynamic>>[]) {
        if (endpoint == ThemeCatalogEndpoint.me && row['id'] != activeId) {
          continue;
        }
        try {
          final theme = ThemeItem.fromJson(row);
          rows.putIfAbsent(theme.id, () => theme);
        } catch (_) {
          /* Ignore malformed legacy metadata. */
        }
      }
    }
    return rows.values.toList(growable: false);
  }

  @override
  Future<List<ThemeItem>> fetchCatalog({
    required CancelToken cancelToken,
  }) async => await readCachedCatalog() ?? kBuiltInThemes;
}
