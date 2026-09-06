import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../kernel/settings/app_settings.dart';
import '../data/theme_repository.dart';
import '../data/local_theme_repository.dart';
import '../data/theme_catalog_cache_storage.dart';

final themeRepositoryProvider = Provider<ThemeRepository>(
  (ref) => LocalThemeRepository(
    ref.watch(themeCatalogCacheStorageProvider),
    activeId: ref.watch(settingsProvider).value?.activeThemeId ?? '',
  ),
);
