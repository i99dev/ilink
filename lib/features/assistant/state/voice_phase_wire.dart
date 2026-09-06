import 'assistant_controller.dart' show AssistantPhase;

/// Wire phase strings pushed to the native bubble (Kotlin `VoicePhase`).
/// Keep in sync with `VoicePhase.fromWire` on the Android side — the
/// background-feedback contract test pins these.
class VoicePhaseWire {
  VoicePhaseWire._();
  static const String idle = 'idle';
  static const String connecting = 'connecting';
  static const String listening = 'listening';
  static const String thinking = 'thinking';
  static const String speaking = 'speaking';
  static const String tool = 'tool';
  static const String error = 'error';
}

/// Pure map: the assistant [phase] (+ whether a car-command tool is currently
/// dispatching) → the wire phase the backgrounded bubble renders.
///
/// A live tool dispatch wins over thinking/speaking so the bubble shows
/// "running a command" the moment the action fires; but `idle` and `error`
/// always dominate (a stale dispatch must never keep the bubble lit after the
/// turn ends or mask a failure). Pure — no Riverpod/platform — so every
/// branch is unit-tested.
String voicePhaseWireFor(AssistantPhase phase, {bool toolActive = false}) {
  switch (phase) {
    case AssistantPhase.idle:
      return VoicePhaseWire.idle;
    case AssistantPhase.error:
      return VoicePhaseWire.error;
    case AssistantPhase.connecting:
      return toolActive ? VoicePhaseWire.tool : VoicePhaseWire.connecting;
    case AssistantPhase.listening:
      return toolActive ? VoicePhaseWire.tool : VoicePhaseWire.listening;
    case AssistantPhase.thinking:
      return toolActive ? VoicePhaseWire.tool : VoicePhaseWire.thinking;
    case AssistantPhase.speaking:
      return toolActive ? VoicePhaseWire.tool : VoicePhaseWire.speaking;
  }
}
