import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/local_mini_app_repository.dart';
import '../data/mini_app_catalog_cache_storage.dart';
import '../data/mini_app_repository.dart';
import '../data/mini_app_install_storage.dart';

final miniAppRepositoryProvider = Provider<MiniAppRepository>(
  (ref) => LocalMiniAppRepository(
    ref.watch(miniAppCatalogCacheStorageProvider),
    ref.watch(miniAppInstallStorageProvider),
  ),
);
