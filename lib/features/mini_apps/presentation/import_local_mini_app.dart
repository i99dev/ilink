import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/catalog_endpoint.dart';
import '../data/local_mini_app_grants.dart';
import 'mini_app_install_consent.dart';
import '../data/installed_mini_app_store.dart';
import '../data/mini_app_catalog_cache_storage.dart';
import '../data/mini_app_install_storage.dart';
import '../domain/mini_app.dart';
import '../domain/mini_app_compat.dart';
import '../state/mini_app_providers.dart';

/// Import requires explicit scoped consent bound to the archive checksum.
Future<void> importLocalMiniApp(BuildContext context, WidgetRef ref) async {
  try {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gz', 'tgz'],
    );
    final path = selection?.files.single.path;
    if (path == null) return;
    final file = File(path);
    if (await file.length() > InstalledMiniAppStore.maxArchiveBytes) {
      throw const FormatException('Bundle exceeds 100 MiB');
    }
    final bytes = await file.readAsBytes();
    final store = ref.read(installedMiniAppStoreProvider);
    final row = await store.inspectLocalBundle(bytes);
    final existingCert = await ref
        .read(miniAppInstallStorageProvider)
        .certHashFor(row['id'] as String);
    if (existingCert != null && existingCert.isNotEmpty) {
      throw StateError(
        'This id belongs to a legacy signed extension and cannot be replaced by an unsigned local bundle.',
      );
    }
    if (!context.mounted) return;
    final names = (row['name'] as Map).cast<String, String>();
    final scopes = await showMiniAppScopeConsent(
      context,
      name: names['en'] ?? names.values.first,
      requested: (row['permissions'] as List).cast<String>(),
      network: (row['network'] as List).cast<String>(),
    );
    if (scopes == null) return;
    final app = MiniApp(
      id: row['id'] as String,
      name: names,
      description:
          (row['description'] as Map?)?.cast<String, String>() ?? const {},
      icon: '',
      url: '',
      version: row['version'] as String,
      minHostVersion: row['minHostVersion'] as String? ?? '0.0.0',
      category: row['category'] as String? ?? 'other',
      bundleUrl: '',
      bundleSha256: row['bundleSha256'] as String,
      requires: MiniAppRequires.fromJson(row['requires']),
      network: (row['network'] as List).cast<String>(),
    );
    // Suspend grants while installed files are being replaced.
    await ref.read(miniAppInstallStorageProvider).updateBundleSha(app.id, null);
    await store.install(app, cancelToken: CancelToken(), localBytes: bytes);
    final entryPath = await store.indexHtmlPath(app.id);
    if (entryPath == null) {
      throw StateError('Installed bundle is missing index.html');
    }
    row['url'] = File(entryPath).uri.toString();
    // Local import does not trust publisher-supplied remote visual URLs.
    row['icon'] = '';
    row.remove('coverImage');
    row.remove('screenshots');
    final cache = ref.read(miniAppCatalogCacheStorageProvider);
    for (final endpoint in CatalogEndpoint.values) {
      final existing = await cache.read(endpoint: endpoint);
      await cache.write([
        for (final old in existing?.rawApps ?? <Map<String, dynamic>>[])
          if (old['id'] != app.id) old,
        if (endpoint == CatalogEndpoint.public) row,
      ], endpoint: endpoint);
    }
    await ref
        .read(miniAppInstallStorageProvider)
        .install(app.id, bundleSha256: app.bundleSha256);
    await ref
        .read(miniAppInstallStorageProvider)
        .updateBundleSha(app.id, app.bundleSha256);
    await ref
        .read(localMiniAppGrantsProvider)
        .approve(app.id, app.bundleSha256, scopes);
    ref.invalidate(miniAppCatalogProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mini-app installed locally.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}
