import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/features/mini_apps/data/catalog_endpoint.dart';
import 'package:ilink/features/mini_apps/data/local_mini_app_repository.dart';
import 'package:ilink/features/mini_apps/data/mini_app_catalog_cache_storage.dart';
import 'package:ilink/features/mini_apps/data/mini_app_install_storage.dart';

void main() {
  test(
    'standalone migration keeps installed private apps and omits uninstalled metadata',
    () async {
      SharedPreferences.setMockInitialValues({});
      final cache = MiniAppCatalogCacheStorage(SharedPreferences.getInstance);
      final installed = MiniAppInstallStorage(SharedPreferences.getInstance);
      await installed.install('saved');
      await cache.write([
        {
          'id': 'saved',
          'name': {'en': 'Saved'},
        },
        {
          'id': 'uninstalled',
          'name': {'en': 'Other'},
        },
      ], endpoint: CatalogEndpoint.me);
      final repo = LocalMiniAppRepository(
        cache,
        installed,
        bundledCatalog: () async => [],
      );
      final apps = await repo.fetchCatalog(cancelToken: CancelToken());
      expect(apps.map((a) => a.id), ['saved']);
      expect(apps.single.localizedName('en'), 'Saved');
    },
  );
  test('fresh standalone library is empty without a network client', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = LocalMiniAppRepository(
      MiniAppCatalogCacheStorage(SharedPreferences.getInstance),
      MiniAppInstallStorage(SharedPreferences.getInstance),
      bundledCatalog: () async => [],
    );
    expect(await repo.fetchCatalog(cancelToken: CancelToken()), isEmpty);
  });
  test(
    'bundled public apps are discoverable before install without network',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repo = LocalMiniAppRepository(
        MiniAppCatalogCacheStorage(SharedPreferences.getInstance),
        MiniAppInstallStorage(SharedPreferences.getInstance),
        bundledCatalog: () async => [
          {
            'id': 'bundled',
            'name': {'en': 'Bundled'},
            'bundleUrl': 'asset://offline/example.tar.gz',
          },
        ],
      );
      final apps = await repo.fetchCatalog(cancelToken: CancelToken());
      expect(apps.single.id, 'bundled');
      expect(apps.single.isInstalled, isFalse);
    },
  );
}
