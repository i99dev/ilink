import '../domain/station.dart';

/// Top-level playback status the controller cares about. A thin abstraction
/// over whatever the concrete player emits — keeps the controller free of
/// just_audio types so tests don't need a real ExoPlayer.
enum RadioPlaybackStatus { idle, loading, playing, paused, error }

class RadioPlaybackState {
  const RadioPlaybackState({
    required this.status,
    this.station,
    this.errorMessage,
  });

  final RadioPlaybackStatus status;
  final Station? station;
  final String? errorMessage;
}

/// Player-side abstraction. RadioController consumes this interface so the
/// real just_audio_background player and a FakeRadioPlayer can be swapped
/// in tests. No platform imports ever leak past this seam — per the
/// project's "keep platform imports isolated" axis.
abstract interface class RadioPlayer {
  /// Stream of status transitions. Must emit the current state on listen
  /// so late subscribers don't miss whatever's playing.
  Stream<RadioPlaybackState> get state;

  RadioPlaybackState get current;

  Future<void> play(Station station);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// Free native resources. Called from the controller's ref.onDispose.
  Future<void> dispose();
}
