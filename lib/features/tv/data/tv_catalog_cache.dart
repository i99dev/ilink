import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/tv_catalog.dart';

/// Persist-once SharedPreferences cache for catalogue content (the
/// iptv-rest-api JSON). Same contract as radio's `CuratedCache`:
///
/// The index + per-group payloads are fetched once and cached indefinitely;
/// subsequent sessions read straight from the cache. The user blows it away
/// from the TV screen's refresh affordance (the controller calls [clear]
/// before re-fetching) to pick up a freshly rebuilt catalogue.
///
/// Sync reads, async writes — payloads are small (index ≤~16 KB, a group
/// shard ≤~75 KB) so they sit comfortably in prefs.
class TvCatalogCache {
  TvCatalogCache(this._prefs);

  final SharedPreferences _prefs;

  static const _kIndexKey = 'tv.catalog.index.v1';
  static const _kGroupPrefix = 'tv.catalog.group.v1.';

  TvCatalogIndex? readIndex() =>
      _readJsonObj(_kIndexKey, TvCatalogIndex.fromJson);

  Future<void> writeIndex(TvCatalogIndex idx) async {
    await _prefs.setString(_kIndexKey, jsonEncode(idx.toJson()));
  }

  TvChannelGroup? readGroup(String id) =>
      _readJsonObj(_kGroupPrefix + id, TvChannelGroup.fromJson);

  Future<void> writeGroup(TvChannelGroup group) async {
    await _prefs.setString(
      _kGroupPrefix + group.id,
      jsonEncode(group.toJson()),
    );
  }

  /// Wipes the index AND every cached group — the "Refresh" affordance.
  Future<void> clear() async {
    final futures = <Future<void>>[_prefs.remove(_kIndexKey).then((_) {})];
    for (final k in _prefs.getKeys()) {
      if (k.startsWith(_kGroupPrefix)) {
        futures.add(_prefs.remove(k).then((_) {}));
      }
    }
    await Future.wait(futures);
  }

  T? _readJsonObj<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null; // corrupt entry → cache miss; next write replaces.
    }
  }
}
