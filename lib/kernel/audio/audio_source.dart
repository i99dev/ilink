/// Which in-app audio source most recently started playing.
///
/// Used by the voice playback coordinator to resume the *right* source after
/// a voice turn — radio vs TV — instead of always assuming radio. Kept a bare
/// enum (no Riverpod) so the pure `VoicePlaybackArbiter` can depend on it
/// without pulling in the framework.
enum AudioSource {
  /// Nothing of ours is the current source (idle, or an external app like
  /// Spotify owns audio — which the OS restores on focus release).
  none,

  /// Our just_audio radio.
  radio,

  /// The native TV player (media3 ExoPlayer; self-manages audio focus).
  tv,
}
