/// Noise-environment preset chosen by the user (Settings UI). Kept in
/// `kernel/settings/` so [AppSettings] can persist + restore it without
/// reaching into the voice feature.
///
/// The full VAD engine + its event types live in
/// `features/voice/domain/voice_activity_detector.dart` — that file
/// re-exports this enum so existing voice-side callers keep their
/// imports unchanged.
///
/// Bias the on/off threshold offsets above the auto-tracked ambient
/// floor; absolute dBFS dials are intentionally hidden.
library;

enum VadNoisePreset {
  /// Parked, AC off — most sensitive. on +12 / off +8 dB above ambient.
  quiet,

  /// City driving — default. on +15 / off +10 dB above ambient.
  normal,

  /// Freeway, windows down — least sensitive. on +20 / off +12 dB.
  noisy;

  double get onOffsetDb => switch (this) {
    VadNoisePreset.quiet => 12.0,
    VadNoisePreset.normal => 15.0,
    VadNoisePreset.noisy => 20.0,
  };

  double get offOffsetDb => switch (this) {
    VadNoisePreset.quiet => 8.0,
    VadNoisePreset.normal => 10.0,
    VadNoisePreset.noisy => 12.0,
  };
}
