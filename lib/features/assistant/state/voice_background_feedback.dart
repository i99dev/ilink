import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../voice/data/voice_service_bridge.dart';
import '../../voice/state/voice_controller.dart'
    show recentToolDispatchProvider, RecentToolDispatch;
import 'assistant_controller.dart';
import 'voice_phase_wire.dart';

/// Pushes the live voice phase (+ active tool) to the native side so the
/// backgrounded floating bubble can render the matching glyph + earcon —
/// giving wheel-button users the same "listening / thinking / speaking /
/// running a command" feedback they get from the in-app UI when foregrounded.
///
/// Listens to both [assistantPhaseProvider] and [recentToolDispatchProvider]
/// and pushes the combined state on either change (a tool dispatch overlays
/// "running a command" via [voicePhaseWireFor]). Cheap — the native side
/// no-ops visually when there's no bubble (foreground), so we don't gate on
/// background state here.
///
/// `Provider<void>` — side effects only; mount once from a long-lived widget
/// (the dash shell) via `ref.watch`, alongside [voicePlaybackCoordinatorProvider].
final voiceBackgroundFeedbackProvider = Provider<void>((ref) {
  void push() {
    final phase = ref.read(assistantPhaseProvider);
    final dispatch = ref.read(recentToolDispatchProvider);
    ref
        .read(voiceServiceBridgeProvider)
        .setVoicePhase(
          voicePhaseWireFor(phase, toolActive: dispatch != null),
          dispatch?.toolName,
        );
  }

  ref.listen<AssistantPhase>(assistantPhaseProvider, (_, _) => push());
  ref.listen<RecentToolDispatch?>(recentToolDispatchProvider, (_, _) => push());
});
