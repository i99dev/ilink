import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/voice/state/voice_controller.dart';
import '../../state/assistant_controller.dart';

/// Full-screen invisible tap-catcher that ends the assistant session
/// the moment the user taps anywhere on the page area. Mounted in the
/// dash shell's Stack BELOW the floating dock and the assistant
/// content cards, so:
///
///  - taps on page content (Home/Radio/Settings underneath)  → stop
///  - taps on the dock (mic, screens dock) → normal dock behaviour
///  - taps on the assistant reply card → stays interactive
///
/// Active phases: anything that isn't `idle`. That deliberately
/// includes `error` — the error pill needs an obvious way to dismiss
/// without re-tapping mic (which would *start a new session*, the
/// opposite of what an annoyed user wants). Tapping anywhere clears
/// the error back to `idle` via `VoiceController.stop()` (documented
/// safe to call from any state, including error).
///
/// When the assistant is idle the widget renders nothing — zero
/// hit-test surface, zero perf cost in the common case.
///
/// Why this exists: the mic button alone is small + at the bottom of
/// the screen — a driver mid-sentence shouldn't have to hunt for it
/// to cancel, and an error pill that lingers until you find the right
/// button feels broken. "Tap the screen to make it stop" is the
/// affordance every new user reaches for first.
class AssistantStopOnTap extends ConsumerWidget {
  const AssistantStopOnTap({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(assistantPhaseProvider);
    if (phase == AssistantPhase.idle) return const SizedBox.shrink();
    return Positioned.fill(
      child: GestureDetector(
        // opaque so the tap is captured here instead of falling through
        // to a child further down the page widget tree.
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(voiceControllerProvider.notifier).stop(),
      ),
    );
  }
}
