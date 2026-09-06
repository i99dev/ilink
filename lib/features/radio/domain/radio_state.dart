import 'station.dart';

/// Sealed state exposed to the UI by [RadioController]. Subtypes map 1:1
/// to the player's top-level status so UI widgets can switch on
/// `runtimeType` without digging into nested fields.
///
/// Pattern matches `VoiceSessionState` in lib/features/voice/state/voice_controller.dart
/// — the project's established shape for Notifier-held state.
sealed class RadioState {
  const RadioState();
}

class RadioIdle extends RadioState {
  const RadioIdle();
}

/// Transient — awaiting the first byte of the stream. Distinct from
/// [RadioPlaying] so the UI can show a spinner instead of a waveform.
class RadioLoading extends RadioState {
  const RadioLoading(this.station);
  final Station station;
}

class RadioPlaying extends RadioState {
  const RadioPlaying(this.station);
  final Station station;
}

class RadioPaused extends RadioState {
  const RadioPaused(this.station);
  final Station station;
}

class RadioError extends RadioState {
  const RadioError(this.message, {this.station});
  final String message;

  /// Present when the error relates to a specific station (stream refused,
  /// codec mismatch). Null for directory/search failures.
  final Station? station;
}
