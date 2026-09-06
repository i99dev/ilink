import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/features/themes/data/local_theme_repository.dart';
import 'package:ilink/features/themes/data/theme_catalog_cache_storage.dart';
import 'package:ilink/features/themes/data/theme_catalog_endpoint.dart';
import 'package:ilink/features/themes/data/built_in_themes.dart';

void main() {
  test(
    'saved active private palette survives standalone migration with bundled defaults',
    () async {
      SharedPreferences.setMockInitialValues({});
      final cache = ThemeCatalogCacheStorage(SharedPreferences.getInstance);
      await cache.write([
        {
          'id': 'saved-theme',
          'name': {'en': 'Saved'},
        },
        {
          'id': 'unselected',
          'name': {'en': 'Other'},
        },
      ], endpoint: ThemeCatalogEndpoint.me);
      final repo = LocalThemeRepository(cache, activeId: 'saved-theme');
      final themes = await repo.fetchCatalog(cancelToken: CancelToken());
      expect(themes.map((t) => t.id), contains('saved-theme'));
      expect(themes.map((t) => t.id), isNot(contains('unselected')));
      for (final theme in kBuiltInThemes) {
        expect(themes.map((t) => t.id), contains(theme.id));
      }
    },
  );
}
