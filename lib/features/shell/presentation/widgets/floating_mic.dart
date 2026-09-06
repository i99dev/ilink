import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/voice/ondevice/ondevice_voice_controller.dart';
import '../../../../features/voice/presentation/voice_commands_sheet.dart';
import '../../../../features/voice/presentation/voice_intro_gate.dart';
import '../../../../features/voice/presentation/voice_mode_picker.dart';
import '../../../../features/voice/state/voice_access_gate.dart';
import '../../../../features/voice/state/voice_controller.dart';
import '../../../assistant/state/assistant_controller.dart';

/// Standalone floating mic — the primary voice control, decoupled from
/// the nav dock so it stays anchored at a fixed corner across every
/// screen the shell presents (home, mini-apps, radio, dev).
///
/// Placement is driver-side: LHD markets (default) anchor to the
/// bottom-left, RHD markets to the bottom-right. The DashShell consumes
/// [AppSettings.driverSide] and positions a single instance of this
/// widget; nothing inside this file knows about the side decision —
/// keeps the mic widget testable in isolation and makes it trivial to
/// drop a second instance for a copilot mic later if that ever ships.
///
/// **Gesture contract**:
///   * **Tap** (idle) — opens a voice session. The mic auto-closes
///     the moment the assistant finishes the turn (command-style).
///     Use for "lock the doors", "set AC to 22", "what's the weather".
///   * **Tap while active** — stops the session.
class FloatingMic extends ConsumerStatefulWidget {
  const FloatingMic({super.key, this.size = defaultSize});

  /// Diameter of the mic button. Default 72 matches the legacy
  /// dock-mic centerpiece — keeps thumb-target ergonomics unchanged.
  final double size;

  static const double defaultSize = 72;

  @override
  ConsumerState<FloatingMic> createState() => _FloatingMicState();
}

class _FloatingMicState extends ConsumerState<FloatingMic>
    with SingleTickerProviderStateMixin {
  /// Drives the expanding "listening" rings behind the mic. A plain
  /// forward `repeat()` (0→1, loop) — each cycle a ring grows out from the
  /// button edge and fades, the familiar assistant affordance. Runs only
  /// while a session is active; stopped + reset to 0 when idle so an
  /// inactive mic is perfectly still and costs no frames.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Idempotent: start the loop when the session goes active, stop + reset
  /// when it goes idle. Safe to call every build (guards on isAnimating so
  /// it never restarts mid-cycle).
  void _syncPulse(bool active) {
    if (active) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Master kill-switch: when the user disabled voice in Settings,
    // the floating mic vanishes from the shell entirely.
    if (!ref.watch(voiceVisibilityProvider)) return const SizedBox.shrink();

    final size = widget.size;
    final phase = ref.watch(assistantPhaseProvider);
    final onDeviceListening =
        ref.watch(onDeviceVoiceControllerProvider.select((s) => s.status)) ==
        OnDeviceVoiceStatus.listening;
    final cs = Theme.of(context).colorScheme;
    final active =
        onDeviceListening ||
        (phase != AssistantPhase.idle && phase != AssistantPhase.error);
    final listening = onDeviceListening || phase == AssistantPhase.listening;
    final error = phase == AssistantPhase.error;
    final fill = error
        ? AppColors.warning
        : listening
        ? AppColors.secondary
        : active
        ? AppColors.accent
        : cs.surfaceContainerHigh;
    final iconColor = active || error ? Colors.white : cs.onSurface;
    final icon = error
        ? Icons.mic_off_rounded
        : listening
        ? Icons.graphic_eq_rounded
        : Icons.mic_rounded;

    final recentDispatch = ref.watch(recentToolDispatchProvider);

    // Run the listening pulse only while the session is live.
    _syncPulse(active);

    final button = Semantics(
      button: true,
      label: 'Assistant',
      hint: 'Tap to talk',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        // Drop shadow lifts the mic visually off whatever screen content
        // sits behind it. Heavier than the dock's shadow because the dock
        // has a glass background to anchor it; the standalone mic is on its
        // own, so the shadow does the anchoring. A coloured glow when active
        // keeps the button itself "lit" between ring pulses.
        elevation: active ? 8 : 4,
        shadowColor: active ? fill.withAlpha(180) : Colors.black,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _onTap(context, active, onDeviceListening),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: fill.withAlpha(150),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, color: iconColor, size: 30),
          ),
        ),
      ),
    );

    final micBox = SizedBox(
      width: size,
      height: size,
      // Expanding rings paint behind the (statically-built) button via
      // Transform.scale, so they overflow the SizedBox harmlessly and
      // the mic's anchored position in the shell never shifts.
      child: _MicPulse(
        controller: _pulse,
        active: active,
        color: fill,
        size: size,
        child: button,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (recentDispatch != null) _DispatchPill(dispatch: recentDispatch),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            micBox,
            // "?" help affordance — opens the offline-commands sheet so a
            // driver can discover what runs for free on-device. Sits BESIDE
            // the mic; hidden while a session is live to keep it clean.
            if (!active) ...[
              const SizedBox(width: 8),
              _HelpButton(onTap: () => showVoiceCommandsSheet(context, ref)),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _onTap(
    BuildContext context,
    bool active,
    bool onDeviceListening,
  ) async {
    if (active) {
      if (onDeviceListening) {
        // Cancel just the on-device capture; keeps the Hey BYD wake loop armed.
        unawaited(
          ref.read(onDeviceVoiceControllerProvider.notifier).cancelManualTurn(),
        );
      } else {
        unawaited(ref.read(voiceControllerProvider.notifier).stop());
      }
      return;
    }
    // Idle → start a turn. First tap ever (hands-free off) shows the one-time
    // "Hey BYD" intro sheet and intercepts THIS tap (no turn); every later tap
    // falls straight through. Centralised in [maybeShowVoiceIntro].
    if (await maybeShowVoiceIntro(context, ref)) return;
    if (!context.mounted) return;
    unawaited(showVoiceModePicker(context, ref));
  }
}

/// Small circular "?" beside the mic. Tapping it opens the offline-commands
/// help sheet — a low-key discoverability affordance that never competes with
/// the mic itself (smaller, muted, and gone while a session is active).
class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Offline voice commands',
      child: Material(
        color: cs.surfaceContainerHigh,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              Icons.question_mark_rounded,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Concentric "listening" pulse rendered behind the mic while a voice
/// session is active — the familiar assistant affordance, unmistakable at a
/// glance. Two soft rings, half a cycle out of phase so the effect is
/// continuous, each grown out from the button edge and faded via
/// [Transform.scale] (paint-only, so they overflow the parent without
/// changing layout or eating taps). When inactive, the [child] renders
/// alone with zero animation cost.
///
/// Driven by a forward-`repeat()` [controller] (value 0→1, looping); the
/// per-ring `(value + phase) % 1` keeps each ring's own 0→1 progress.
class _MicPulse extends StatelessWidget {
  const _MicPulse({
    required this.controller,
    required this.active,
    required this.color,
    required this.size,
    required this.child,
  });

  final Animation<double> controller;
  final bool active;
  final Color color;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [_ring(0.0), _ring(0.5), child],
    );
  }

  Widget _ring(double phase) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = (controller.value + phase) % 1.0;
        // Grow to ~1.9× and fade to nothing as it expands.
        final alpha = ((1.0 - t) * 150).round().clamp(0, 255);
        return IgnorePointer(
          child: Transform.scale(
            scale: 1.0 + 0.9 * t,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withAlpha(alpha),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DispatchPill extends StatelessWidget {
  const _DispatchPill({required this.dispatch});
  final RecentToolDispatch dispatch;

  @override
  Widget build(BuildContext context) {
    final failed = dispatch.error != null;
    final confirmed = dispatch.onDeviceConfirmed;
    final accent = failed
        ? AppColors.warning
        : confirmed
        ? AppColors.accent
        : dispatch.predictiveFired
        ? AppColors.primary
        : AppColors.accent;
    final icon = failed
        ? Icons.error_outline_rounded
        : confirmed
        ? Icons.check_circle_rounded
        : dispatch.predictiveFired
        ? Icons.bolt_rounded
        : Icons.check_rounded;
    // On failure show "<label> · <reason>" (or just the reason); else the
    // friendly label / raw tool name.
    final text = failed
        ? (dispatch.label == null
              ? dispatch.error!
              : '${dispatch.label} · ${dispatch.error}')
        : (dispatch.label ?? dispatch.toolName);
    final prose = failed || confirmed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: accent.withAlpha(38),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withAlpha(120), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: accent),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                fontFamily: prose ? null : 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
