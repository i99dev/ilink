import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/voice/state/voice_controller.dart';
import '../../../kernel/audio/audio_source_registry.dart';
import '../../radio/domain/radio_state.dart';
import '../../radio/domain/station.dart';
import '../../radio/providers.dart';
import 'assistant_controller.dart';
import 'voice_playback_arbiter.dart';

/// The single owner of voice↔media arbitration. The voice session knows
/// nothing about the radio; everything that has to happen to other audio
/// when the assistant opens/closes is decided here.
///
/// Two responsibilities, both delegated to the pure [VoicePlaybackArbiter]
/// so the decision logic is unit-testable and this provider stays a thin
/// wiring layer:
///
/// 1. **Auto-cancel voice when audio starts playing.** The radio controller
///    bumps [playbackIntentProvider] synchronously at the top of every play
///    method (before the just_audio buffer call), so we react to the user's
///    intent, not the audible-state transition 100-500 ms later. Silent
///    tools ("lock doors") never bump it.
///
/// 2. **Silence the radio for the mic, then restore it.** just_audio does
///    NOT react to the Kotlin-side `AUDIOFOCUS_GAIN_TRANSIENT` the voice
///    service requests, so we pause it when a turn starts and re-play the
///    captured [Station] when the turn ends. Re-playing fresh (vs a paused-
///    buffer resume) is correct for *live* radio — the user rejoins the live
///    edge. The TV/ExoPlayer player ducks itself via `handleAudioFocus`, so
///    it needs no coordination here.
///
/// `Provider<void>` — no surfaced state; side effects live in the
/// `ref.listen` callbacks. Mount once via
/// `ref.watch(voicePlaybackCoordinatorProvider)` from a long-lived widget
/// (the dash shell) to keep the listeners alive.
final voicePlaybackCoordinatorProvider = Provider<void>((ref) {
  // Same instance for the container's lifetime, so its cross-event state
  // survives provider rebuilds.
  final arbiter = VoicePlaybackArbiter();

  // 1. Playback-intent bumps during an active turn cancel the mic.
  ref.listen<int>(playbackIntentProvider, (prev, next) {
    if (prev == next) return;
    final voiceActive = VoicePlaybackArbiter.isActive(
      ref.read(assistantPhaseProvider),
    );
    if (arbiter.onPlaybackIntent(voiceActive: voiceActive)) {
      ref.read(voiceControllerProvider.notifier).stop();
    }
  });

  // 2. Capture + pause on entry; restore on exit.
  ref.listen<AssistantPhase>(assistantPhaseProvider, (prev, next) {
    if (prev == next) return;
    final action = arbiter.onPhaseChange(
      prev: prev,
      next: next,
      nowPlaying: _currentlyPlaying(ref.read(radioControllerProvider)),
      lastSource: ref.read(audioSourceProvider),
    );
    switch (action) {
      case PauseRadio():
        ref.read(radioControllerProvider.notifier).pause();
      case RestoreRadio(:final station):
        ref.read(radioControllerProvider.notifier).playStation(station);
      case NoPlaybackAction():
        break;
    }
  });
});

/// The station the radio is actively playing or buffering, or null. A radio
/// the user already paused/stopped isn't captured — we don't auto-resume
/// something they themselves silenced.
Station? _currentlyPlaying(RadioState s) => switch (s) {
  RadioPlaying(:final station) => station,
  RadioLoading(:final station) => station,
  _ => null,
};
