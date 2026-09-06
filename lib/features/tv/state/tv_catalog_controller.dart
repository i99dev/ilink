import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/tv_catalog_api.dart';
import '../data/tv_catalog_cache.dart';
import '../domain/tv_catalog.dart';
import '../providers.dart';
import '../tv_controller.dart';

/// Orchestrator for the catalogue (iptv-rest-api) layer.
///
/// Persist-once contract (mirrors radio's `CuratedPlaylistsController`):
///   * [getIndex] / [loadGroup] return cached results forever once fetched;
///     they only hit the network when the cache is empty.
///   * [refresh] is the explicit escape hatch — wipes the cache and bumps
///     the notifier so any watching `FutureProvider` re-fetches.
///
/// On both cache-hit and cold-fetch a loaded group's channels are folded
/// into [TvController]'s search index so name search / a future voice
/// `play <channel>` find them immediately.
class TvCatalogController extends Notifier<int> {
  late TvCatalogApi _api;
  late TvCatalogCache _cache;

  @override
  int build() {
    _api = ref.read(tvCatalogApiProvider);
    _cache = ref.read(tvCatalogCacheProvider);
    return 0;
  }

  Future<TvCatalogIndex> getIndex() async {
    final cached = _cache.readIndex();
    if (cached != null) return cached;
    final fresh = await _api.fetchIndex();
    await _cache.writeIndex(fresh);
    return fresh;
  }

  Future<TvChannelGroup> loadGroup(TvCatalogGroup group) async {
    final cached = _cache.readGroup(group.id);
    if (cached != null) {
      _index(cached);
      return cached;
    }
    final fresh = await _api.fetchGroup(group);
    await _cache.writeGroup(fresh);
    _index(fresh);
    return fresh;
  }

  Future<void> refresh() async {
    // Keep the saved library; standalone refresh never discards local media.
    state = state + 1;
  }

  void _index(TvChannelGroup group) {
    ref.read(tvControllerProvider.notifier).indexChannels(group.channels);
  }
}
