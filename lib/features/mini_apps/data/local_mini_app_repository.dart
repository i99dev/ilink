import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import '../domain/mini_app.dart';
import '../domain/mini_app_compat.dart';
import '../domain/mini_app_track.dart';
import 'catalog_endpoint.dart';
import 'mini_app_bridge_config.dart';
import 'mini_app_catalog_cache_storage.dart';
import 'mini_app_repository.dart';
import 'mini_app_install_storage.dart';

class LocalMiniAppRepository extends MiniAppRepository {
  LocalMiniAppRepository(
    this._cache,
    this._installed, {
    Future<List<Map<String, dynamic>>> Function()? bundledCatalog,
  }) : _bundledCatalog = bundledCatalog ?? _loadBundled;
  final Future<List<Map<String, dynamic>>> Function() _bundledCatalog;
  static Future<List<Map<String, dynamic>>> _loadBundled() async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/offline/mini_apps/catalog.json'),
    );
    return (json as List).whereType<Map<String, dynamic>>().toList(
      growable: false,
    );
  }

  final MiniAppInstallStorage _installed;
  final MiniAppCatalogCacheStorage _cache;
  @override
  Future<List<MiniApp>?> readCachedCatalog() async {
    final installed = await _installed.load();
    final rows = <String, MiniApp>{};
    for (final row in await _bundledCatalog()) {
      final app = _miniAppFromJson(row);
      rows[app.id] = app;
    }
    for (final endpoint in CatalogEndpoint.values) {
      final cache = await _cache.read(endpoint: endpoint);
      for (final row in cache?.rawApps ?? <Map<String, dynamic>>[]) {
        final id = row['id'];
        // Retain previously installed private/beta apps, without exposing
        // uninstalled account-scoped catalog entries or contacting their host.
        if (id is! String || !installed.containsKey(id)) continue;
        try {
          rows[id] = _miniAppFromJson(row);
        } catch (_) {
          /* skip corrupt row */
        }
      }
    }
    return rows.values.toList(growable: false);
  }

  @override
  Future<List<MiniApp>> fetchCatalog({
    required CancelToken cancelToken,
  }) async => await readCachedCatalog() ?? const [];
  static MiniApp _miniAppFromJson(Map<String, dynamic> json) {
    // Field naming follows the SDK manifest schema (see
    // `sdk-ilink/packages/types/src/manifest.ts` and the Pydantic
    // mirror in `app/api/v1/mini_apps_publish/schemas.py`): camelCase
    // on the wire, e.g. `icon` not `icon_url`. Defensive reads on
    // every scalar — one malformed row falls back to defaults rather
    // than crashing the whole catalog.
    final localizedName =
        (json['name'] as Map?)?.cast<String, String>() ??
        {'en': (json['id'] as String? ?? '')};
    final localizedDescription =
        (json['description'] as Map?)?.cast<String, String>() ?? const {};
    return MiniApp(
      id: (json['id'] as String?) ?? '',
      name: localizedName,
      description: localizedDescription,
      icon: (json['icon'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      version: (json['version'] as String?) ?? '1.0.0',
      minHostVersion: (json['minHostVersion'] as String?) ?? '0.0.0',
      category: (json['category'] as String?) ?? 'other',
      bundleUrl: (json['bundleUrl'] as String?) ?? '',
      bundleSha256: (json['bundleSha256'] as String?) ?? '',
      safeWhileDriving: (json['safeWhileDriving'] as bool?) ?? false,
      // Backend marks privileged apps with this flag in the catalog
      // row. Default false on missing field.
      privileged: (json['privileged'] as bool?) ?? false,

      track: MiniAppTrack.fromWire(json['track'] as String?),
      releaseNotes: json['releaseNotes'] as String?,
      // Cover banner — backend ships `coverImage` as nullable string.
      coverImage: json['coverImage'] as String?,
      // Screenshot gallery — backend ships `screenshots` as nullable
      // list of strings. Filter empties so a malformed row doesn't
      // produce broken-image placeholders. Tolerate non-list values
      // (older backends that haven't been migrated yet).
      screenshots: _readScreenshots(json),
      // Hard vehicle-compat block. Lenient parse (null when absent /
      // malformed); the launch-time `evaluateCompatibility()` gate
      // fail-closes on a too-new schema rather than on parse errors.
      requires: MiniAppRequires.fromJson(json['requires']),
      // Declared external-egress origins. Re-validated + canonicalized on
      // the car (defense in depth — never trust the catalog blob), capped
      // at 10. A malformed entry is dropped, not fatal.
      network: _readNetwork(json),
    );
  }

  static List<String> _readNetwork(Map<String, Object?> json) {
    final raw = json['network'];
    if (raw is! List) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      final origin = normalizeMiniAppOrigin(entry);
      if (origin == null || seen.contains(origin)) continue;
      seen.add(origin);
      out.add(origin);
      if (out.length >= 10) break;
    }
    return List.unmodifiable(out);
  }

  static List<String> _readScreenshots(Map<String, Object?> json) {
    final raw = json['screenshots'];
    if (raw is! List) return const <String>[];
    return raw
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
  }
}
