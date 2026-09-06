import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_source.dart';

/// Tracks the most-recently-started in-app audio source ([AudioSource]).
///
/// Radio ([RadioController.playStation]) and TV ([TvController.playChannel])
/// each [mark] themselves when they begin playback; the voice playback
/// coordinator reads the current value at voice-start to decide what to
/// resume when the turn ends. We only need "what started last" — not stop
/// events — because the coordinator also checks that the source is *actually*
/// still playing before resuming it.
class AudioSourceRegistry extends Notifier<AudioSource> {
  @override
  AudioSource build() => AudioSource.none;

  void mark(AudioSource source) {
    if (state != source) state = source;
  }
}

final audioSourceProvider = NotifierProvider<AudioSourceRegistry, AudioSource>(
  AudioSourceRegistry.new,
);
