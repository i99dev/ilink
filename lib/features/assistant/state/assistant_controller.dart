import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/voice/state/voice_controller.dart';

/// UI-facing projection of [VoiceSessionState]. Kept as a small enum so
/// widgets can `.select()` on it without depending on the whole sealed
/// state hierarchy — fewer rebuilds, looser coupling.
enum AssistantPhase { idle, connecting, listening, thinking, speaking, error }

/// Map the voice controller's sealed state to the overlay's phase.
AssistantPhase _phaseOf(VoiceSessionState s) => switch (s) {
  VoiceIdle() => AssistantPhase.idle,
  VoiceConnecting() => AssistantPhase.connecting,
  VoiceReconnecting() => AssistantPhase.connecting,
  VoiceListening() => AssistantPhase.listening,
  VoiceThinking() => AssistantPhase.thinking,
  VoiceSpeaking() => AssistantPhase.speaking,
  VoiceError() => AssistantPhase.error,
};

/// Derived, read-only. The UI flips the session via [voiceControllerProvider].
///
/// `.select(_phaseOf)` narrows the watched value to the derived phase so
/// emits that don't change the phase (e.g. a different `VoiceError.message`
/// while still in the error phase) don't rebuild every phase consumer.
final assistantPhaseProvider = Provider<AssistantPhase>((ref) {
  return ref.watch(voiceControllerProvider.select(_phaseOf));
});

/// Exposed for the overlay so it can show an error message without
/// reaching into the voice state directly. Narrowed to just the message
/// so transitions between non-error states don't re-notify subscribers.
final assistantErrorMessageProvider = Provider<String?>((ref) {
  return ref.watch(
    voiceControllerProvider.select((s) => s is VoiceError ? s.message : null),
  );
});

/// Classified error code — used by the overlay to pick a user-facing
/// copy string ("OpenAI balance exhausted", "Invalid API key", etc.)
/// rather than surfacing the raw exception. Null when not in error.
final assistantErrorCodeProvider = Provider<VoiceErrorCode?>((ref) {
  return ref.watch(
    voiceControllerProvider.select((s) => s is VoiceError ? s.code : null),
  );
});
