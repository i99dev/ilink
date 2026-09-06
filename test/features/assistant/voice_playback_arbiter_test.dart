import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/assistant/state/assistant_controller.dart';
import 'package:ilink/features/assistant/state/voice_playback_arbiter.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:ilink/kernel/audio/audio_source.dart';

/// Pure-logic coverage for the voice↔radio arbiter — the decision core that
/// fixes "media never resumes after a voice turn". No Riverpod, no platform.
void main() {
  Station st(String id) =>
      Station(id: id, sourceUuid: 'u-$id', name: id, streamUrl: 'http://x/$id');

  group('VoicePlaybackArbiter', () {
    test('pauses the playing station on start, restores it on a clean end', () {
      final a = VoicePlaybackArbiter();
      final s = st('jazz');

      expect(
        a.onPhaseChange(
          prev: AssistantPhase.idle,
          next: AssistantPhase.connecting,
          nowPlaying: s,
        ),
        isA<PauseRadio>(),
      );

      final end = a.onPhaseChange(
        prev: AssistantPhase.speaking,
        next: AssistantPhase.idle,
        nowPlaying: null,
      );
      expect(end, isA<RestoreRadio>());
      expect((end as RestoreRadio).station, s);
    });

    test('nothing playing at start → no pause and no restore', () {
      final a = VoicePlaybackArbiter();
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.idle,
          next: AssistantPhase.connecting,
          nowPlaying: null,
        ),
        isA<NoPlaybackAction>(),
      );
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.listening,
          next: AssistantPhase.idle,
          nowPlaying: null,
        ),
        isA<NoPlaybackAction>(),
      );
    });

    test('playback (re)started mid-turn suppresses the restore', () {
      final a = VoicePlaybackArbiter();
      a.onPhaseChange(
        prev: AssistantPhase.idle,
        next: AssistantPhase.connecting,
        nowPlaying: st('rock'),
      );
      // An assistant "play X" tool (or the user) starts new audio mid-turn.
      expect(a.onPlaybackIntent(voiceActive: true), isTrue);

      final end = a.onPhaseChange(
        prev: AssistantPhase.speaking,
        next: AssistantPhase.idle,
        nowPlaying: null,
      );
      expect(end, isA<NoPlaybackAction>());
    });

    test('onPlaybackIntent is a no-op while voice is inactive', () {
      final a = VoicePlaybackArbiter();
      expect(a.onPlaybackIntent(voiceActive: false), isFalse);
    });

    test('an errored turn still restores (never strands the user silent)', () {
      final a = VoicePlaybackArbiter();
      final s = st('news');
      a.onPhaseChange(
        prev: AssistantPhase.idle,
        next: AssistantPhase.listening,
        nowPlaying: s,
      );
      final end = a.onPhaseChange(
        prev: AssistantPhase.thinking,
        next: AssistantPhase.error,
        nowPlaying: null,
      );
      expect(end, isA<RestoreRadio>());
      expect((end as RestoreRadio).station, s);
    });

    test('error → idle does not double-restore', () {
      final a = VoicePlaybackArbiter();
      a.onPhaseChange(
        prev: AssistantPhase.idle,
        next: AssistantPhase.listening,
        nowPlaying: st('news'),
      );
      a.onPhaseChange(
        prev: AssistantPhase.thinking,
        next: AssistantPhase.error,
        nowPlaying: null,
      ); // restores here
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.error,
          next: AssistantPhase.idle,
          nowPlaying: null,
        ),
        isA<NoPlaybackAction>(),
      );
    });

    test('intra-session transitions do nothing and keep the capture', () {
      final a = VoicePlaybackArbiter();
      final s = st('lofi');
      a.onPhaseChange(
        prev: AssistantPhase.idle,
        next: AssistantPhase.connecting,
        nowPlaying: s,
      );
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.connecting,
          next: AssistantPhase.listening,
          nowPlaying: null,
        ),
        isA<NoPlaybackAction>(),
      );
      final end = a.onPhaseChange(
        prev: AssistantPhase.speaking,
        next: AssistantPhase.idle,
        nowPlaying: null,
      );
      expect(end, isA<RestoreRadio>());
      expect((end as RestoreRadio).station, s);
    });
  });

  group('VoicePlaybackArbiter — source-aware resume', () {
    test('TV is the last source → radio is NOT paused or restored', () {
      final a = VoicePlaybackArbiter();
      // A stale radio station may still report "playing", but TV took over.
      final start = a.onPhaseChange(
        prev: AssistantPhase.idle,
        next: AssistantPhase.connecting,
        nowPlaying: st('jazz'),
        lastSource: AudioSource.tv,
      );
      expect(start, isA<NoPlaybackAction>());

      final end = a.onPhaseChange(
        prev: AssistantPhase.speaking,
        next: AssistantPhase.idle,
        nowPlaying: null,
        lastSource: AudioSource.tv,
      );
      // Nothing to restore — TV's ExoPlayer re-acquires focus itself.
      expect(end, isA<NoPlaybackAction>());
    });

    test('external/none last source → radio left alone', () {
      final a = VoicePlaybackArbiter();
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.idle,
          next: AssistantPhase.listening,
          nowPlaying: st('jazz'),
          lastSource: AudioSource.none,
        ),
        isA<NoPlaybackAction>(),
      );
    });

    test('radio last source & playing → pause + restore (default path)', () {
      final a = VoicePlaybackArbiter();
      final s = st('jazz');
      expect(
        a.onPhaseChange(
          prev: AssistantPhase.idle,
          next: AssistantPhase.listening,
          nowPlaying: s,
          lastSource: AudioSource.radio,
        ),
        isA<PauseRadio>(),
      );
      final end = a.onPhaseChange(
        prev: AssistantPhase.speaking,
        next: AssistantPhase.idle,
        nowPlaying: null,
        lastSource: AudioSource.radio,
      );
      expect((end as RestoreRadio).station, s);
    });
  });
}
