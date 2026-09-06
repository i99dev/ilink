import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/channel.dart';

/// Persists the user's favourited channels as **full [Channel] snapshots**.
///
/// A catalogue entry has no stable server-side record and the catalogue is
/// rebuilt daily, so a favourite must carry everything it needs to be shown
/// and played without a re-fetch. Snapshots are bounded by user action (a
/// handful of channels, ~½ KB each) so they stay in SharedPreferences.
///
/// Contract: idempotent, order-preserving, most-recently-added first.
class TvFavoritesStore {
  TvFavoritesStore(this._prefs);

  final SharedPreferences _prefs;
  static const _kKey = 'tv.favorites.v1';

  List<Channel> getAll() {
    final raw = _prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(Channel.fromJson)
            .toList(growable: false);
      }
    } catch (_) {
      // Corrupted blob — drop it rather than crash; next write overwrites.
    }
    return const [];
  }

  bool isFavorite(String channelId) => getAll().any((c) => c.id == channelId);

  Future<void> add(Channel channel) async {
    final current = getAll();
    if (current.any((c) => c.id == channel.id)) return;
    await _save([channel, ...current]);
  }

  Future<void> remove(String channelId) async {
    final current = getAll();
    if (!current.any((c) => c.id == channelId)) return;
    await _save(
      current.where((c) => c.id != channelId).toList(growable: false),
    );
  }

  Future<void> _save(List<Channel> channels) async {
    await _prefs.setString(
      _kKey,
      jsonEncode(channels.map((c) => c.toJson()).toList(growable: false)),
    );
  }
}
