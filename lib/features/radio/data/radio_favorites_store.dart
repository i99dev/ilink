import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/station.dart';

/// Persists the user's favourited stations as **full [Station]
/// snapshots**.
///
/// Before the M3U migration this stored bare radio-browser UUIDs and
/// re-hydrated each one through the backend's cached `/stations/{id}`
/// point lookup. There is no such endpoint anymore — an M3U entry has no
/// stable server-side record — so the favourite must carry everything it
/// needs to be displayed and played offline. Snapshots are bounded by
/// user action (a handful of stations, ~½ KB each) so they stay in
/// SharedPreferences; the large *catalogue* blobs do not (see
/// [FilePlaylistCache](file_playlist_cache.dart)).
///
/// One-time migration: any pre-existing v1 (`radio.favorites`) blob held
/// UUIDs that cannot resolve against the M3U catalogue, so it is dropped
/// the first time this store is touched. This is the accepted, explicit
/// cost of the source change — old favourites are cleared once.
///
/// Contract (unchanged from v1): idempotent, order-preserving,
/// most-recently-added first — `RadioController.nextFavorite` rotates in
/// that order.
class RadioFavoritesStore {
  RadioFavoritesStore(this._prefs);

  final SharedPreferences _prefs;
  static const _kKey = 'radio.favorites.v2';
  static const _kLegacyKey = 'radio.favorites';

  List<Station> getAll() {
    _dropLegacy();
    final raw = _prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(Station.fromJson)
            .toList(growable: false);
      }
    } catch (_) {
      // Corrupted blob — drop it rather than surfacing a crash. The next
      // write overwrites cleanly.
    }
    return const [];
  }

  bool isFavorite(String stationId) => getAll().any((s) => s.id == stationId);

  Future<void> add(Station station) async {
    final current = getAll();
    if (current.any((s) => s.id == station.id)) return;
    // Most-recently-added first — nextFavorite consumes in this order.
    await _save([station, ...current]);
  }

  Future<void> remove(String stationId) async {
    final current = getAll();
    if (!current.any((s) => s.id == stationId)) return;
    await _save(
      current.where((s) => s.id != stationId).toList(growable: false),
    );
  }

  Future<void> _save(List<Station> stations) async {
    await _prefs.setString(
      _kKey,
      jsonEncode(stations.map((s) => s.toJson()).toList(growable: false)),
    );
  }

  /// Idempotent: clears the obsolete v1 UUID blob exactly once. The
  /// async removal is fire-and-forget — SharedPreferences updates its
  /// in-memory map synchronously, so subsequent reads are already
  /// consistent without awaiting the disk flush.
  void _dropLegacy() {
    if (_prefs.getString(_kLegacyKey) != null) {
      unawaited(_prefs.remove(_kLegacyKey));
    }
  }
}
