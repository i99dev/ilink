import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_endpoint.dart';

/// On-device record of the last catalog response we received. Stored
/// alongside the server's `ETag` so the next fetch can ride
/// `If-None-Match` and short-circuit to a 304 when nothing changed.
///
/// Why we cache the raw API rows (not parsed [MiniApp]s): keeps schema
/// drift symmetric — whatever the parser at fetch time accepts is
/// exactly what the cache writes, so adding/removing fields on the
/// client model never invalidates a stored payload. Mirrors
/// [MiniAppInstallStorage]'s factory-injection shape so tests pass an
/// in-memory SharedPreferences without globally mocking it.
///
/// Why SharedPreferences and not sqflite: the catalog payload is small
/// (KB-scale even at hundreds of apps) and read-once-on-open, so a
/// single string entry beats the cost of a sqflite migration. Falls
/// back to "no cache" gracefully on every error path — the worst case
/// is one round-trip, which is what the network-only path was already
/// paying.
class MiniAppCatalogCacheEntry {
  const MiniAppCatalogCacheEntry({
    required this.rawApps,
    required this.etag,
    required this.cachedAt,
  });

  /// Raw catalog rows from the API, untouched. Re-parsed via the
  /// repository's `_miniAppFromJson` on read.
  final List<Map<String, dynamic>> rawApps;

  /// `ETag` value from the last 200 response, or null if the server
  /// didn't send one. Replayed as `If-None-Match` on the next call.
  final String? etag;

  final DateTime cachedAt;
}

class MiniAppCatalogCacheStorage {
  MiniAppCatalogCacheStorage(this._prefsFactory);

  final Future<SharedPreferences> Function() _prefsFactory;

  Future<SharedPreferences> get _prefs => _prefsFactory();

  /// Returns the last successfully stored catalog payload for
  /// [endpoint], or null on miss / corrupt blob. Never throws —
  /// a corrupted pref must not jam the Store screen into an error
  /// state, same contract as [MiniAppInstallStorage.load].
  Future<MiniAppCatalogCacheEntry?> read({
    required CatalogEndpoint endpoint,
  }) async {
    final raw = (await _prefs).getString(endpoint.cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final at = decoded['at'];
      final apps = decoded['v'];
      if (at is! int || apps is! List) return null;
      final rows = <Map<String, dynamic>>[];
      for (final row in apps) {
        if (row is Map<String, dynamic>) rows.add(row);
        // A non-map row in storage is junk — skip it rather than
        // refuse the whole cache.
      }
      final etag = decoded['etag'];
      return MiniAppCatalogCacheEntry(
        rawApps: rows,
        etag: etag is String && etag.isNotEmpty ? etag : null,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );
    } catch (_) {
      return null;
    }
  }

  /// Overwrites the cache with the given API rows + ETag. ETag may be
  /// null when the server didn't send one (e.g., a misconfigured proxy
  /// stripped the header) — we still cache the body so the offline
  /// path works, the next fetch just won't be able to 304.
  Future<void> write(
    List<Map<String, dynamic>> rawApps, {
    String? etag,
    required CatalogEndpoint endpoint,
  }) async {
    final envelope = jsonEncode({
      'at': DateTime.now().millisecondsSinceEpoch,
      'etag': etag,
      'v': rawApps,
    });
    await (await _prefs).setString(endpoint.cacheKey, envelope);
  }

  /// Drops every endpoint's cached payload. Wired up for sign-out and
  /// dev tooling (the Settings screen exposes a "Clear app data"
  /// affordance later). Iterates [CatalogEndpoint.values] so a new
  /// endpoint is automatically covered without churning this file.
  Future<void> clear() async {
    final prefs = await _prefs;
    for (final endpoint in CatalogEndpoint.values) {
      await prefs.remove(endpoint.cacheKey);
    }
  }
}

final miniAppCatalogCacheStorageProvider = Provider<MiniAppCatalogCacheStorage>(
  (_) {
    return MiniAppCatalogCacheStorage(SharedPreferences.getInstance);
  },
);
