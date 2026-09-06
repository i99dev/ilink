import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../domain/station.dart';
import 'radio_player.dart';
import '../../../kernel/services/optional_services.dart';
import '../../../kernel/services/local_media.dart';

/// Production [RadioPlayer] — delegates to just_audio with a
/// just_audio_background MediaItem so the OS shows transport controls on
/// the lock screen and Android Auto picks up playback metadata.
///
/// Only this file imports `just_audio` / `just_audio_background`. The rest
/// of the radio feature speaks [RadioPlaybackState] / [Station].
class JustAudioRadioPlayer implements RadioPlayer {
  JustAudioRadioPlayer({required bool Function() streamingEnabled})
    : _streamingEnabled = streamingEnabled,
      _player = AudioPlayer() {
    // One broadcast controller multiplexes playback events + our own
    // station/error metadata. We emit on every just_audio PlayerState
    // change and translate processing/playing flags into our coarse
    // [RadioPlaybackStatus] enum.
    _controller = StreamController<RadioPlaybackState>.broadcast(
      onListen: () => _controller.add(_current),
    );
    _playerSub = _player.playerStateStream.listen(_onPlayerState);
  }

  final AudioPlayer _player;
  final bool Function() _streamingEnabled;
  late final StreamController<RadioPlaybackState> _controller;
  StreamSubscription<PlayerState>? _playerSub;
  Station? _station;
  RadioPlaybackState _current = const RadioPlaybackState(
    status: RadioPlaybackStatus.idle,
  );

  /// Monotonic id of the current `play()` invocation. Events from an
  /// older source that arrive after a new station has been loaded are
  /// discarded via this generation check — without it, late-arriving
  /// `playing=true` notifications from the previous stream would
  /// overwrite our new-loading state.
  int _playGeneration = 0;
  bool _switching = false;

  @override
  Stream<RadioPlaybackState> get state => _controller.stream;

  @override
  RadioPlaybackState get current => _current;

  @override
  Future<void> play(Station station) async {
    if (!_streamingEnabled() && !isLocalMedia(station.streamUrl)) {
      throw const ServiceDisabled(OptionalService.streaming);
    }
    final gen = ++_playGeneration;
    final hadPrevious = _station != null;
    _station = station;
    _switching = true;
    _emit(RadioPlaybackStatus.loading, station: station);
    try {
      // Explicitly stop any in-flight stream before loading the next one.
      // Without this, just_audio occasionally keeps the previous source
      // attached when switching stations (especially for live HLS/ICY
      // streams that can't be seeked to a "graceful end"), so a second
      // tap appears to do nothing and the original station keeps playing.
      if (hadPrevious) {
        await _player.stop();
        if (gen != _playGeneration) return; // superseded by a newer play()
      }
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(station.streamUrl),
          tag: MediaItem(
            // MediaItem.id must be unique per source; the station's stable
            // UUID fits perfectly and lets MediaSession clients (Android
            // Auto) dedupe repeats.
            id: station.id,
            album: station.countryName ?? 'Radio',
            title: station.name,
            artist: station.language ?? '',
            artUri: _streamingEnabled() ? _parseArt(station.favicon) : null,
          ),
        ),
      );
      if (gen != _playGeneration) return;
      if (!_streamingEnabled() && !isLocalMedia(station.streamUrl)) {
        await stop();
        return;
      }
      // The new source is attached, so player-state events now describe
      // THIS station — stop suppressing them before playback starts.
      _switching = false;
      // NOT awaited: just_audio's `play()` completes when playback
      // *finishes*, which for a live radio stream is never. Awaiting it
      // stranded `_switching` at true, so `_onPlayerState` dropped every
      // update and the UI sat on "loading…" while audio was audible.
      unawaited(
        _player.play().catchError((Object e) {
          if (gen != _playGeneration) return;
          _emit(
            RadioPlaybackStatus.error,
            station: station,
            errorMessage: e.toString(),
          );
        }),
      );
    } catch (e) {
      if (gen != _playGeneration) return;
      _emit(
        RadioPlaybackStatus.error,
        station: station,
        errorMessage: e.toString(),
      );
      rethrow;
    } finally {
      if (gen == _playGeneration) _switching = false;
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() async {
    if (!_streamingEnabled() && !isLocalMedia(_station?.streamUrl ?? '')) {
      throw const ServiceDisabled(OptionalService.streaming);
    }
    await _player.play();
  }

  @override
  Future<void> stop() async {
    // Bump the generation so any in-flight play() knows it's been
    // superseded and shouldn't resume after awaiting setAudioSource.
    _playGeneration++;
    _switching = false;
    _station = null;
    await _player.stop();
    _emit(RadioPlaybackStatus.idle);
  }

  @override
  Future<void> dispose() async {
    await _playerSub?.cancel();
    await _player.dispose();
    await _controller.close();
  }

  void _onPlayerState(PlayerState ps) {
    // While we're mid-switch (stop → setAudioSource → play) just_audio
    // emits transient idle/buffering events from the OLD source winding
    // down. Suppress them — we've already emitted `loading` for the new
    // station and don't want the UI to flicker to "idle" in between.
    if (_switching) return;

    // Error handling flows through the try/catch in [play]; here we only
    // translate the "well-behaved" states to our enum.
    final status = switch (ps.processingState) {
      ProcessingState.idle => RadioPlaybackStatus.idle,
      ProcessingState.loading ||
      ProcessingState.buffering => RadioPlaybackStatus.loading,
      ProcessingState.ready =>
        ps.playing ? RadioPlaybackStatus.playing : RadioPlaybackStatus.paused,
      // `completed` on a live radio stream means the source ended
      // unexpectedly (network drop, 404 mid-stream). Treat it as idle
      // but *drop* the station reference so the UI doesn't keep showing
      // "Paused — BBC" after the stream died.
      ProcessingState.completed => RadioPlaybackStatus.idle,
    };
    _emit(
      status,
      station: status == RadioPlaybackStatus.idle ? null : _station,
    );
  }

  void _emit(
    RadioPlaybackStatus status, {
    Station? station,
    String? errorMessage,
  }) {
    _current = RadioPlaybackState(
      status: status,
      station: station,
      errorMessage: errorMessage,
    );
    _controller.add(_current);
  }

  Uri? _parseArt(String? favicon) {
    if (favicon == null || favicon.isEmpty) return null;
    try {
      return Uri.parse(favicon);
    } catch (_) {
      return null;
    }
  }
}
