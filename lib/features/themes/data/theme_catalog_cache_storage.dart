import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_catalog_endpoint.dart';

/// How long a cached theme catalog is considered "fresh". Past this the
/// repository still serves the cache instantly (offline-first) but a
/// background revalidation is preferred. Mirrors the mini-app
/// stale-while-revalidate discipline; the ETag short-circuits the
/// network re-parse when nothing changed.
const Duration kThemeCatalogTtl = Duration(hours: 6);

/// On-device record of the last theme-catalog response. Stored with the
/// server's `ETag` so the next fetch can ride `If-None-Match` and
/// short-circuit to a 304. We cache the raw API rows (not parsed
/// [ThemeItem]s) so the cache stays symmetric with whatever the parser
/// accepts — adding/removing client fields never invalidates a stored
/// payload. A direct port of [MiniAppCatalogCacheEntry].
class ThemeCatalogCacheEntry {
  const ThemeCatalogCacheEntry({
    required this.rawThemes,
    required this.etag,
    required this.cachedAt,
  });

  /// Raw catalog rows from the API, untouched. Re-parsed via
  /// `ThemeItem.fromJson` on read.
  final List<Map<String, dynamic>> rawThemes;

  /// `ETag` value from the last 200 response, or null. Replayed as
  /// `If-None-Match` on the next call.
  final String? etag;

  final DateTime cachedAt;

  /// True when the entry is older than [kThemeCatalogTtl]. The repo
  /// uses this only to bias toward revalidation; a stale entry is still
  /// served (better last-known data than a spinner on a flaky link).
  bool get isStale => DateTime.now().difference(cachedAt) > kThemeCatalogTtl;
}

/// SharedPreferences-backed cache for the theme catalog. Never throws —
/// a corrupt pref must not jam the Themes gallery into an error state.
/// Mirrors [MiniAppCatalogCacheStorage] one-for-one.
class ThemeCatalogCacheStorage {
  ThemeCatalogCacheStorage(this._prefsFactory);

  final Future<SharedPreferences> Function() _prefsFactory;

  Future<SharedPreferences> get _prefs => _prefsFactory();

  /// Returns the last stored payload for [endpoint], or null on miss /
  /// corrupt blob.
  Future<ThemeCatalogCacheEntry?> read({
    required ThemeCatalogEndpoint endpoint,
  }) async {
    final raw = (await _prefs).getString(endpoint.cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final at = decoded['at'];
      final themes = decoded['v'];
      if (at is! int || themes is! List) return null;
      final rows = <Map<String, dynamic>>[];
      for (final row in themes) {
        if (row is Map<String, dynamic>) rows.add(row);
      }
      final etag = decoded['etag'];
      return ThemeCatalogCacheEntry(
        rawThemes: rows,
        etag: etag is String && etag.isNotEmpty ? etag : null,
        cachedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );
    } catch (_) {
      return null;
    }
  }

  /// Overwrites the cache with the given API rows + ETag. ETag may be
  /// null when the server didn't send one — we still cache the body so
  /// the offline path works; the next fetch just can't 304.
  Future<void> write(
    List<Map<String, dynamic>> rawThemes, {
    String? etag,
    required ThemeCatalogEndpoint endpoint,
  }) async {
    final envelope = jsonEncode({
      'at': DateTime.now().millisecondsSinceEpoch,
      'etag': etag,
      'v': rawThemes,
    });
    await (await _prefs).setString(endpoint.cacheKey, envelope);
  }

  /// Drops every endpoint's cached payload (sign-out / dev tooling).
  Future<void> clear() async {
    final prefs = await _prefs;
    for (final endpoint in ThemeCatalogEndpoint.values) {
      await prefs.remove(endpoint.cacheKey);
    }
  }
}

final themeCatalogCacheStorageProvider = Provider<ThemeCatalogCacheStorage>(
  (_) => ThemeCatalogCacheStorage(SharedPreferences.getInstance),
);
