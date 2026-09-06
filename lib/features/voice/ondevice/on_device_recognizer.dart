import 'voice_grammar.dart';

/// Seams for the native on-device layer that the on-car Phase-0 spike
/// (see README) fills in. Pure-Dart contracts so the centralized brain
/// (grammar + matcher + trigger funnel) is built and unit-tested now, and
/// the platform engines drop in behind these interfaces without touching
/// any of the logic above them.
///
/// Planned implementations (Kotlin ↔ Dart over a MethodChannel/EventChannel,
/// mirroring the existing `voice_service_bridge.dart`):
///   - [WakeWordDetector] → openWakeWord TFLite, the cheap always-on gate.
///   - [OnDeviceRecognizer] → Vosk (Kaldi) grammar-constrained recognizer,
///     loaded with [VoiceGrammar.toVoskGrammarJson] for the command turn.

/// A transcript chunk from the on-device recognizer.
class OnDeviceResult {
  const OnDeviceResult({
    required this.text,
    required this.isFinal,
    this.confidence,
  });

  final String text;

  /// Vosk emits streaming partials then one final per utterance. The
  /// fast-path matches on [isFinal] results; partials drive the live HUD.
  final bool isFinal;

  /// 0..1 when the engine reports it; null otherwise.
  final double? confidence;
}

/// Grammar-constrained on-device speech recognizer (Vosk). Recognition is
/// scoped to [VoiceGrammar] so decoding is near-instant and accurate over
/// the fixed command set, with `[unk]` catching out-of-grammar speech.
abstract class OnDeviceRecognizer {
  /// Load the [version]'s model + apply the grammar. [version] is the catalog
  /// model id (e.g. `en-0.15`) that selects WHICH per-language model on disk to
  /// load. Idempotent; re-applying a new grammar/version is allowed.
  Future<void> applyGrammar(VoiceGrammar grammar, {required String version});

  /// Final + partial results for the current utterance.
  Stream<OnDeviceResult> get results;

  /// Begin/stop feeding mic frames. The single audio owner (Phase 1b) is
  /// responsible for not double-opening AudioRecord — see README M3.
  Future<void> start();
  Future<void> stop();

  Future<void> dispose();
}

abstract class WakeWordDetector {
  /// Fires once per wake detection. The integration layer maps each event
  /// to a `TriggerSource.wakeWord` turn through the one trigger funnel.
  Stream<WakeEvent> get detections;

  /// Arm/disarm the detector. Disarm must be honoured promptly for the
  /// mic-preemption and fleet-kill paths (README M1/M4).
  Future<void> arm();
  Future<void> disarm();

  Future<void> dispose();
}

class WakeEvent {
  const WakeEvent({required this.phraseId, this.confidence});

  /// Which wake phrase fired (e.g. `hey_byd_en`, `hey_byd_ar`) — set per
  /// the central per-phrase config map.
  final String phraseId;
  final double? confidence;
}
