import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/_car_domain/command/command_outcome.dart';
import '../../kernel/audio/audio_source.dart';
import '../../kernel/audio/audio_source_registry.dart';
import 'data/radio_favorites_store.dart';
import 'data/radio_player.dart';
import 'domain/radio_state.dart';
import 'domain/station.dart';
import 'providers.dart';

/// Orchestrates every radio action — player control, favourites
/// rotation, and the small in-memory station index that backs the voice
/// path. Methods return [CommandOutcome] so the same closures plug
/// straight into `CarCommand.exec` for voice + WebSocket dispatch;
/// internal UI calls simply inspect `outcome.ok`.
///
/// Station discovery (browse / search / "play X" voice) no longer hits
/// any remote catalogue. The app's three-layer model is now:
///
///   1. **Curated playlists** (m3u-rest-api JSON) — fetched lazily via
///      `CuratedPlaylistsController`; only stations from a
///      currently-loaded curated entry land in [_knownStations].
///   2. **User-imported playlists** (file / URL) — indexed into
///      [_knownStations] on every `userPlaylistsVersionProvider` bump.
///   3. **Favourites** — full [Station] snapshots; also folded into the
///      index on `favoritesVersionProvider` bumps.
///
/// Voice [`playByName`] / [`playStationById`] resolve against
/// [_knownStations]; nothing crosses the network.
///
/// State transitions follow the player's event stream, not the method
/// return value — a `play` call returns as soon as just_audio accepts the
/// source, but [RadioState] only flips to `RadioPlaying` when the stream
/// actually starts decoding. Same split as VoiceController.
class RadioController extends Notifier<RadioState> {
  late RadioPlayer _player;
  late RadioFavoritesStore _favorites;
  StreamSubscription<RadioPlaybackState>? _playerSub;

  /// Source-agnostic, case-folded-name → Station index used by
  /// [playByName] and [playStationById]. Rebuilt on favourites + user-
  /// playlist version bumps, plus a one-shot demo preload at build.
  final Map<String, Station> _knownStations = <String, Station>{};

  @override
  RadioState build() {
    _player = ref.read(radioPlayerProvider);
    _favorites = ref.read(radioFavoritesStoreProvider);
    _playerSub = _player.state.listen(_onPlayback);

    // Refresh the voice-search index on every signal that changes the
    // set of known stations. The listeners are scoped to the notifier's
    // lifetime — ref.listen registered inside build() is auto-disposed.
    ref.listen<int>(favoritesVersionProvider, (_, _) => _rebuildIndex());
    ref.listen<int>(userPlaylistsVersionProvider, (_, _) => _rebuildIndex());
    // Cold boot: the user-playlist store hydrates from disk async, so
    // the _rebuildIndex() below runs against an empty set. Re-run once
    // hydration lands so voice search can resolve already-persisted
    // playlists without waiting for a mutation.
    ref.listen(userPlaylistsHydratedProvider, (_, _) => _rebuildIndex());
    _rebuildIndex();

    ref.onDispose(() async {
      await _playerSub?.cancel();
      // Player lifetime is tied to this notifier — dispose here rather than
      // in providers.onDispose so tests that override the player in the
      // provider still clean up their own fakes.
      await _player.dispose();
    });
    return const RadioIdle();
  }

  // --- Commands (also invoked via CarCommand.exec) -------------------------

  Future<CommandOutcome> playByName(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return CommandOutcome.failure('empty query');
    Station? best;
    for (final s in _knownStations.values) {
      if (s.name.toLowerCase().contains(q)) {
        best = s;
        break;
      }
    }
    if (best == null) {
      return CommandOutcome.failure('no station matches "$query"');
    }
    return playStation(best);
  }

  Future<CommandOutcome> playStationById(String stationId) async {
    // Favourites first (they carry their own snapshot — playable even if
    // not currently loaded from any other source).
    for (final s in _favorites.getAll()) {
      if (s.id == stationId) return playStation(s);
    }
    final s = _knownStations[stationId];
    if (s == null) {
      return CommandOutcome.failure('unknown station "$stationId"');
    }
    return playStation(s);
  }

  Future<CommandOutcome> playStation(Station station) async {
    // Synchronous "playback starting" signal — fires before the
    // just_audio buffer call so the assistant gets stopped the
    // instant a play is initiated, not when the decode finishes.
    // Funnel point: playByName / playStationById / nextFavorite /
    // every UI tap eventually lands here, so one bump covers them all.
    ref.read(playbackIntentProvider.notifier).signalStarting();
    // Mark radio as the current in-app audio source so the voice
    // coordinator resumes radio (not TV/external) after a turn.
    ref.read(audioSourceProvider.notifier).mark(AudioSource.radio);
    return _run('play(${station.id})', () async {
      await _player.play(station);
      return {'station_id': station.id, 'name': station.name};
    });
  }

  Future<CommandOutcome> pause() => _run('pause', () => _player.pause());
  Future<CommandOutcome> resume() => _run('resume', () => _player.resume());
  Future<CommandOutcome> stop() => _run('stop', () => _player.stop());

  /// Rotate to the next favourited station. Wraps around; fails cleanly
  /// when there are no favourites. Plays the persisted snapshot directly
  /// — no directory round-trip, works offline.
  Future<CommandOutcome> nextFavorite() async {
    final favs = _favorites.getAll();
    if (favs.isEmpty) return CommandOutcome.failure('no favorites');
    final currentId = _currentStation()?.id;
    var nextIndex = 0;
    if (currentId != null) {
      final pos = favs.indexWhere((s) => s.id == currentId);
      nextIndex = pos < 0 ? 0 : (pos + 1) % favs.length;
    }
    return playStation(favs[nextIndex]);
  }

  /// Toggle a favourite. Favouriting persists a full [Station] snapshot
  /// (there is no backend point-lookup to re-hydrate from anymore), so
  /// the caller passes the station it already has. [station] is optional
  /// only to keep the command-shaped `(stationId)` signature: when it is
  /// absent we fall back to the now-playing station or the in-memory
  /// known-station index.
  Future<CommandOutcome> toggleFavorite(String stationId, {Station? station}) {
    return _run('toggleFavorite($stationId)', () async {
      if (_favorites.isFavorite(stationId)) {
        await _favorites.remove(stationId);
      } else {
        final snapshot =
            station ?? _matchingCurrent(stationId) ?? _knownStations[stationId];
        if (snapshot == null) {
          throw StateError('cannot favourite unknown station "$stationId"');
        }
        await _favorites.add(snapshot);
      }
      // Broadcast the change so FavoritesRow / StationTile's heart
      // icon / anyone else watching favourites re-queries the store.
      ref.read(favoritesVersionProvider.notifier).signalChanged();
      return {
        'station_id': stationId,
        'favorited': _favorites.isFavorite(stationId),
      };
    });
  }

  /// Uniform outcome wrapper for the `CommandOutcome`-returning methods.
  /// [label] is just for the failure message, matching
  /// [CarControllerBase.action]'s shape for car commands. [fn] may return
  /// a data map (carried through as `success.data`) or `void`.
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

  // --- UI-only queries (not commands) --------------------------------------

  /// The user's favourited stations. Direct read of the persisted
  /// snapshots — instant, offline, no per-id directory fetch.
  Future<List<Station>> favorites() async => _favorites.getAll();

  bool isFavorite(String stationId) => _favorites.isFavorite(stationId);

  /// Inject stations from any source (a freshly loaded demo, a user
  /// playlist, etc.) into the voice-search index. Indexing is purely
  /// additive — last-write wins on id collisions, which is the right
  /// behaviour for a user playlist overriding a demo entry.
  void indexStations(Iterable<Station> stations) {
    for (final s in stations) {
      _knownStations[s.id] = s;
    }
  }

  // --- Internal ------------------------------------------------------------

  void _rebuildIndex() {
    // Reseed from sources we can read synchronously: favourites (their
    // own store) and user-imported playlists (the userPlaylistsProvider
    // fans out from the same store the importer just wrote to). Demos
    // were eagerly indexed at build via the asset preload path. The
    // result is one flat name-search surface across all three layers.
    for (final s in _favorites.getAll()) {
      _knownStations[s.id] = s;
    }
    for (final pl in ref.read(userPlaylistsProvider)) {
      for (final s in pl.stations) {
        _knownStations[s.id] = s;
      }
    }
  }

  Station? _currentStation() {
    final s = state;
    return switch (s) {
      RadioPlaying(:final station) => station,
      RadioPaused(:final station) => station,
      RadioLoading(:final station) => station,
      RadioError(:final station) => station,
      RadioIdle() => null,
    };
  }

  /// The now-playing station iff it is the one being toggled — lets a
  /// favourite-while-listening snapshot itself with no directory call.
  Station? _matchingCurrent(String stationId) {
    final s = _currentStation();
    return (s != null && s.id == stationId) ? s : null;
  }

  void _onPlayback(RadioPlaybackState ps) {
    state = switch (ps.status) {
      RadioPlaybackStatus.idle => const RadioIdle(),
      RadioPlaybackStatus.loading =>
        ps.station != null ? RadioLoading(ps.station!) : const RadioIdle(),
      RadioPlaybackStatus.playing =>
        ps.station != null ? RadioPlaying(ps.station!) : state,
      RadioPlaybackStatus.paused =>
        ps.station != null ? RadioPaused(ps.station!) : state,
      RadioPlaybackStatus.error => RadioError(
        ps.errorMessage ?? 'playback error',
        station: ps.station,
      ),
    };
  }
}
