import '../../../kernel/audio/audio_source.dart';
import '../../radio/domain/station.dart';
import 'assistant_controller.dart' show AssistantPhase;

/// What the coordinator should do to the radio in response to a voice
/// lifecycle event. Pure data — the provider turns these into
/// `RadioController` calls.
sealed class PlaybackAction {
  const PlaybackAction();
}

/// Do nothing.
class NoPlaybackAction extends PlaybackAction {
  const NoPlaybackAction();
}

/// Silence the radio for the mic.
class PauseRadio extends PlaybackAction {
  const PauseRadio();
}

/// Re-play [station] (the one captured when the turn started).
class RestoreRadio extends PlaybackAction {
  const RestoreRadio(this.station);
  final Station station;
}

/// Pure decision core for [voicePlaybackCoordinatorProvider]. Holds the
/// tiny bit of cross-event state (what was interrupted, whether new playback
/// began mid-turn) and answers "given this event, what should happen to the
/// radio" — with no Riverpod, no platform, so every branch is unit-testable.
///
/// A turn is "active" for any [AssistantPhase] that is neither
/// [AssistantPhase.idle] nor [AssistantPhase.error]; it "starts" when the
/// phase enters the active set and "ends" when it leaves (to idle on a clean
/// finish, or to error on a failure — both restore, so a failed turn never
/// strands the user in silence).
class VoicePlaybackArbiter {
  Station? _interrupted;
  bool _startedDuringVoice = false;

  static bool isActive(AssistantPhase p) =>
      p != AssistantPhase.idle && p != AssistantPhase.error;

  /// A play was (re)started. Returns true if an active voice turn should be
  /// cancelled (audio would otherwise overlap the assistant), and records
  /// that fresh playback began so the end-of-turn restore stands down.
  bool onPlaybackIntent({required bool voiceActive}) {
    if (!voiceActive) return false;
    _startedDuringVoice = true;
    return true;
  }

  /// A phase transition.
  ///
  /// [nowPlaying] is the station the radio is currently playing/loading (else
  /// null). [lastSource] is the most-recently-started in-app audio source.
  ///
  /// We only pause+restore the radio when it is BOTH the last source AND
  /// actually playing. If TV (or an external app) was the last source, we
  /// stay out of the way: TV's ExoPlayer re-acquires audio focus on its own
  /// when voice releases it, and the OS restores an external app — so
  /// resuming radio over them (the old always-radio bug) is exactly what we
  /// must not do.
  PlaybackAction onPhaseChange({
    required AssistantPhase? prev,
    required AssistantPhase next,
    required Station? nowPlaying,
    AudioSource lastSource = AudioSource.radio,
  }) {
    final wasActive = prev != null && isActive(prev);
    final justStarted = !wasActive && isActive(next);
    final justEnded = wasActive && !isActive(next);

    if (justStarted) {
      _startedDuringVoice = false;
      // Capture radio only when it's the source the user was actually
      // listening to; otherwise leave TV/external to OS audio focus.
      final capturable = lastSource == AudioSource.radio ? nowPlaying : null;
      _interrupted = capturable;
      return capturable != null ? const PauseRadio() : const NoPlaybackAction();
    }

    if (justEnded) {
      final toRestore = _startedDuringVoice ? null : _interrupted;
      _interrupted = null;
      _startedDuringVoice = false;
      return toRestore != null
          ? RestoreRadio(toRestore)
          : const NoPlaybackAction();
    }

    return const NoPlaybackAction();
  }
}
