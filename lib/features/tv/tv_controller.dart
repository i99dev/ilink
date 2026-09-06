import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../kernel/audio/audio_source.dart';
import '../../kernel/audio/audio_source_registry.dart';
import '../_car_domain/command/command_outcome.dart';
import 'data/tv_favorites_store.dart';
import 'domain/channel.dart';
import 'domain/tv_state.dart';
import 'providers.dart';

/// Orchestrates TV favourites + the name-search index, and starts playback
/// by launching the **native full-screen player** ([tvIviBridgeProvider]) —
/// embedded Flutter video can't render on this BYD ROM, so there is no
/// in-process player here.
///
/// [TvState] is advisory (set on launch for `playByName`/voice); the browse
/// grid highlights the current channel via [tvLastChannelProvider]. Methods
/// return [CommandOutcome] so they can plug into `CarCommand.exec`.
class TvController extends Notifier<TvState> {
  late TvFavoritesStore _favorites;

  /// Case-folded-name → Channel index backing [playByName]. Rebuilt on
  /// favourites bumps and extended as catalogue groups load.
  final Map<String, Channel> _knownChannels = <String, Channel>{};

  @override
  TvState build() {
    _favorites = ref.read(tvFavoritesStoreProvider);
    ref.listen<int>(tvFavoritesVersionProvider, (_, _) => _rebuildIndex());
    _rebuildIndex();
    return const TvIdle();
  }

  // --- Commands -----------------------------------------------------------

  Future<CommandOutcome> playByName(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return CommandOutcome.failure('empty query');
    for (final c in _knownChannels.values) {
      if (c.name.toLowerCase().contains(q)) return playChannel(c);
    }
    return CommandOutcome.failure('no channel matches "$query"');
  }

  Future<CommandOutcome> playChannelById(String channelId) async {
    for (final c in _favorites.getAll()) {
      if (c.id == channelId) return playChannel(c);
    }
    final c = _knownChannels[channelId];
    if (c == null) {
      return CommandOutcome.failure('unknown channel "$channelId"');
    }
    return playChannel(c);
  }

  /// Launch [channel] in the native full-screen player.
  Future<CommandOutcome> playChannel(Channel channel) async {
    try {
      // Mark TV as the current in-app audio source so the voice coordinator
      // resumes TV (not radio) after a turn — the native player's ExoPlayer
      // re-acquires focus itself once voice releases it.
      ref.read(audioSourceProvider.notifier).mark(AudioSource.tv);
      await ref
          .read(tvIviBridgeProvider)
          .play(
            channels: [channel],
            startIndex: 0,
            maxBitrate: ref.read(tvQualityProvider).maxBitrate,
          );
      ref.read(tvLastChannelProvider.notifier).set(channel.id);
      state = TvPlaying(channel);
      return CommandOutcome.success({
        'channel_id': channel.id,
        'name': channel.name,
      });
    } catch (e) {
      return CommandOutcome.failure('play(${channel.id}) failed: $e');
    }
  }

  Future<CommandOutcome> toggleFavorite(String channelId, {Channel? channel}) {
    return _run('toggleFavorite($channelId)', () async {
      if (_favorites.isFavorite(channelId)) {
        await _favorites.remove(channelId);
      } else {
        final snapshot =
            channel ?? _matchingCurrent(channelId) ?? _knownChannels[channelId];
        if (snapshot == null) {
          throw StateError('cannot favourite unknown channel "$channelId"');
        }
        await _favorites.add(snapshot);
      }
      ref.read(tvFavoritesVersionProvider.notifier).signalChanged();
      return {
        'channel_id': channelId,
        'favorited': _favorites.isFavorite(channelId),
      };
    });
  }

  Future<CommandOutcome> _run(
    String label,
    Future<Object?> Function() fn,
  ) async {
    try {
      final out = await fn();
      if (out is Map<String, dynamic>) return CommandOutcome.success(out);
      return CommandOutcome.success();
    } catch (e) {
      return CommandOutcome.failure('$label failed: $e');
    }
  }

  // --- UI-only queries ----------------------------------------------------

  Future<List<Channel>> favorites() async => _favorites.getAll();

  bool isFavorite(String channelId) => _favorites.isFavorite(channelId);

  /// Inject channels from any source (a freshly loaded catalogue group, a
  /// user import) into the search index. Additive; last-write wins.
  void indexChannels(Iterable<Channel> channels) {
    for (final c in channels) {
      _knownChannels[c.id] = c;
    }
  }

  // --- Internal -----------------------------------------------------------

  void _rebuildIndex() {
    for (final c in _favorites.getAll()) {
      _knownChannels[c.id] = c;
    }
  }

  Channel? _matchingCurrent(String channelId) {
    final s = state;
    final c = s is TvPlaying ? s.channel : null;
    return (c != null && c.id == channelId) ? c : null;
  }
}
