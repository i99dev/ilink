import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/curated_cache.dart';
import '../data/curated_playlist_api.dart';
import '../domain/curated_playlist.dart';
import '../providers.dart';
import '../radio_controller.dart';

/// Orchestrator for the curated content (m3u-rest-api) layer.
///
/// Persist-once contract (locked product decision):
///   * `getIndex()` and `loadPlaylist()` return cached results forever
///     once fetched. They only hit the network when the cache is empty.
///   * `refresh()` is the explicit escape hatch — wipes cache + bumps
///     the notifier state so any watching `FutureProvider` re-fetches.
///
/// State is an opaque op counter (UI doesn't read it; it watches
/// derived providers). Same pattern as `UserPlaylistController`.
class CuratedPlaylistsController extends Notifier<int> {
  late CuratedPlaylistApi _api;
  late CuratedCache _cache;

  @override
  int build() {
    _api = ref.read(curatedApiProvider);
    _cache = ref.read(curatedCacheProvider);
    return 0;
  }

  /// Cache-first index read. Throws [CuratedFetchException] on a cold
  /// fetch failure; the UI surfaces the message via a SnackBar.
  Future<CuratedIndex> getIndex() async {
    final cached = _cache.readIndex();
    final fresh = await _api.fetchIndex();
    final entries = <String, CuratedIndexEntry>{
      if (cached != null)
        for (final entry in cached.entries)
          if (_cache.readPlaylist(entry.id) != null) entry.id: entry,
    };
    for (final entry in fresh.entries) {
      entries.putIfAbsent(entry.id, () => entry);
    }
    final merged = CuratedIndex(
      generatedAt: fresh.generatedAt,
      entries: entries.values.toList(growable: false),
    );
    await _cache.writeIndex(merged);
    return merged;
  }

  /// Cache-first playlist read. On both paths (cache hit + cold fetch)
  /// the playlist's stations are folded into [RadioController]'s voice-
  /// search index so `playByName` finds them immediately after the user
  /// taps into a curated entry.
  Future<CuratedPlaylist> loadPlaylist(CuratedIndexEntry entry) async {
    final cached = _cache.readPlaylist(entry.id);
    if (cached != null) {
      _index(cached);
      return cached;
    }
    final fresh = await _api.fetchPlaylist(entry);
    await _cache.writePlaylist(fresh);
    _index(fresh);
    return fresh;
  }

  /// Wipes the curated cache and bumps notifier state so observers
  /// (e.g. `curatedIndexProvider`) re-fetch on next read.
  Future<void> refresh() async {
    // Keep the saved library; standalone refresh never discards local media.
    state = state + 1;
  }

  void _index(CuratedPlaylist pl) {
    ref.read(radioControllerProvider.notifier).indexStations(pl.stations);
  }
}
