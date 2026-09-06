import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/curated_playlist.dart';

/// Persist-once SharedPreferences cache for curated content (the
/// m3u-rest-api JSON).
///
/// Per the locked product decision: the curated index + per-playlist
/// payloads are fetched ONCE and cached indefinitely. Subsequent
/// sessions read straight from the cache — no TTL refresh, no
/// revalidation. The user can blow it away from the Radio screen's
/// refresh button when they want fresh content (the controller calls
/// [clear] before re-fetching).
///
/// Why prefs (not file-backed)? Curated payloads are small JSON: the
/// index is ~200 KB worst case (5 270 entries × ~40 B each), and a
/// fully-loaded playlist tops out a few hundred KB once capped at
/// [kDefaultStationCap]. The whole catalogue the user actually visits
/// in practice will sit comfortably in prefs — the M3U-fork blobs
/// (multi-MB) that pushed us to a file cache are gone.
///
/// Sync reads, async writes — matches the rest of the radio storage
/// layer (favourites, user-playlists store).
class CuratedCache {
  CuratedCache(this._prefs);

  final SharedPreferences _prefs;

  static const _kIndexKey = 'radio.curated.index.v1';
  static const _kPlaylistPrefix = 'radio.curated.pl.v1.';

  /// Null when the cache is empty / corrupt — the controller treats
  /// that as "go fetch" per the persist-once contract.
  CuratedIndex? readIndex() {
    return _readJsonObj(_kIndexKey, CuratedIndex.fromJson);
  }

  Future<void> writeIndex(CuratedIndex idx) async {
    await _prefs.setString(_kIndexKey, jsonEncode(idx.toJson()));
  }

  CuratedPlaylist? readPlaylist(String id) {
    return _readJsonObj(_kPlaylistPrefix + id, CuratedPlaylist.fromJson);
  }

  Future<void> writePlaylist(CuratedPlaylist pl) async {
    await _prefs.setString(_kPlaylistPrefix + pl.id, jsonEncode(pl.toJson()));
  }

  /// Wipes the index AND every cached playlist. Invoked by the
  /// "Refresh" affordance on the curated category — gives the user a
  /// way to pick up new playlists added to the rest-api repo without
  /// reinstalling the app.
  Future<void> clear() async {
    final futures = <Future<void>>[_prefs.remove(_kIndexKey).then((_) {})];
    for (final k in _prefs.getKeys()) {
      if (k.startsWith(_kPlaylistPrefix)) {
        futures.add(_prefs.remove(k).then((_) {}));
      }
    }
    await Future.wait(futures);
  }

  // --- internal -----------------------------------------------------------

  T? _readJsonObj<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      // Corrupt entry — treat as cache miss; next write replaces.
      return null;
    }
  }
}
