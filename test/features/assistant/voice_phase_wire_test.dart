import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/assistant/state/assistant_controller.dart';
import 'package:ilink/features/assistant/state/voice_phase_wire.dart';

/// Pins the AssistantPhase → wire-phase mapping the native bubble renders.
void main() {
  group('voicePhaseWireFor', () {
    test('maps each phase to its wire string (no tool)', () {
      expect(voicePhaseWireFor(AssistantPhase.idle), VoicePhaseWire.idle);
      expect(
        voicePhaseWireFor(AssistantPhase.connecting),
        VoicePhaseWire.connecting,
      );
      expect(
        voicePhaseWireFor(AssistantPhase.listening),
        VoicePhaseWire.listening,
      );
      expect(
        voicePhaseWireFor(AssistantPhase.thinking),
        VoicePhaseWire.thinking,
      );
      expect(
        voicePhaseWireFor(AssistantPhase.speaking),
        VoicePhaseWire.speaking,
      );
      expect(voicePhaseWireFor(AssistantPhase.error), VoicePhaseWire.error);
    });

    test('an active tool overlays "tool" on the working phases', () {
      for (final p in [
        AssistantPhase.connecting,
        AssistantPhase.listening,
        AssistantPhase.thinking,
        AssistantPhase.speaking,
      ]) {
        expect(
          voicePhaseWireFor(p, toolActive: true),
          VoicePhaseWire.tool,
          reason: 'tool should win over $p',
        );
      }
    });

    test('idle and error dominate even with a lingering tool dispatch', () {
      expect(
        voicePhaseWireFor(AssistantPhase.idle, toolActive: true),
        VoicePhaseWire.idle,
      );
      expect(
        voicePhaseWireFor(AssistantPhase.error, toolActive: true),
        VoicePhaseWire.error,
      );
    });
  });
}
