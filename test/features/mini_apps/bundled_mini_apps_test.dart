import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/installed_mini_app_store.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'every shipped catalog bundle verifies and installs without a server',
    () async {
      final root = await Directory.systemTemp.createTemp('bundled_mini_apps_');
      addTearDown(() => root.delete(recursive: true));
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  error: 'Network forbidden',
                ),
              );
            },
          ),
        );
      final store = InstalledMiniAppStore(
        dio: dio,
        appSupportDirFactory: () async => root,
      );
      final rows =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/offline/mini_apps/catalog.json',
                ),
              )
              as List;
      expect(rows, hasLength(4));
      for (final raw in rows) {
        final row = raw as Map<String, dynamic>;
        final app = MiniApp(
          id: row['id'] as String,
          name: (row['name'] as Map).cast<String, String>(),
          description: const {},
          icon: '',
          url: '',
          version: row['version'] as String,
          minHostVersion: row['minHostVersion'] as String,
          category: row['category'] as String,
          bundleUrl: row['bundleUrl'] as String,
          bundleSha256: row['bundleSha256'] as String,
        );
        final manifest = await store.inspectBundledApp(app);
        expect(manifest['id'], app.id);
        await store.install(app, cancelToken: CancelToken());
        expect(await store.installedVersion(app.id), app.version);
        expect(
          await File((await store.indexHtmlPath(app.id))!).length(),
          greaterThan(0),
        );
      }
    },
  );
}
