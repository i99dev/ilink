import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../features/voice/state/voice_controller.dart';
import '../../state/assistant_controller.dart';

/// Local recognition status and errors, with a large stop target.
class VoiceHud extends ConsumerWidget {
  const VoiceHud({super.key});

  /// Bottom inset — sits above the floating dock + assistant content
  /// panel. Matches the old overlay's lane (was bottom: 260) but
  /// pulls the capsule down + center, where Siri's compact UI lives.
  static const double _bottomInset = 184;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(assistantPhaseProvider);
    final errorCode = ref.watch(assistantErrorCodeProvider);
    final errorMessage = ref.watch(assistantErrorMessageProvider);

    final isHidden = phase == AssistantPhase.idle;

    return Positioned(
      left: 0,
      right: 0,
      bottom: _bottomInset,
      child: IgnorePointer(
        ignoring: isHidden,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.25),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: isHidden
                    ? const SizedBox.shrink(key: ValueKey('hidden'))
                    : _Capsule(
                        key: ValueKey(phase),
                        phase: phase,
                        errorCode: errorCode,
                        errorMessage: errorMessage,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Capsule extends ConsumerWidget {
  const _Capsule({
    super.key,
    required this.phase,
    required this.errorCode,
    required this.errorMessage,
  });

  final AssistantPhase phase;
  final VoiceErrorCode? errorCode;
  final String? errorMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);

    final palette = _paletteFor(phase, cs);
    final isError = phase == AssistantPhase.error;

    final centerText = _centerTextFor(
      phase: phase,
      t: t,
      isError: isError,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );

    final phaseLabel = _phaseLabelFor(phase, t, errorCode: errorCode);

    void onTap() {
      // Any tap on the capsule kills the current activity. While
      // listening / thinking / speaking this is "stop"; while in
      // error it acts as "dismiss" (controller flips to idle on stop).
      ref.read(voiceControllerProvider.notifier).stop();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(36),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(
            minWidth: 280,
            maxWidth: 560,
            minHeight: 64,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withAlpha(238),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: palette.color.withAlpha(150), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: palette.color.withAlpha(110),
                blurRadius: 28,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 32,
                child: _Visualiser(
                  phase: phase,
                  level: 0,
                  color: palette.color,
                ),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    centerText,
                    key: ValueKey(centerText),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              _PhaseChip(label: phaseLabel, color: palette.color),
            ],
          ),
        ),
      ),
    );
  }

  static String _centerTextFor({
    required AssistantPhase phase,
    required S t,
    required bool isError,
    required VoiceErrorCode? errorCode,
    required String? errorMessage,
  }) {
    if (isError) {
      return _voiceErrorCopy[errorCode] ??
          (errorMessage != null && errorMessage.isNotEmpty
              ? 'Voice error: $errorMessage'
              : 'Voice error');
    }
    switch (phase) {
      case AssistantPhase.connecting:
        return t.assistantThinking;
      case AssistantPhase.listening:
        // Echo the most recent transcript while waiting for the next
        // utterance (continued-conversation window). Empty before the
        // first turn → fall back to the listening label.
        return t.assistantListening;
      case AssistantPhase.thinking:
        return t.assistantThinking;
      case AssistantPhase.speaking:
        // While TTS is playing, the audio carries the message —
        // streaming the assistant text into the capsule on top of
        // that reads as visual noise (the words slide through
        // faster than the voice catches up, then re-read by the
        // driver while listening). Keep the user echo on screen
        // instead so the capsule shows *what was asked* — useful
        // context anchoring the spoken reply — and let the
        // waveform do the "AI is talking" signalling on its own.
        return t.assistantListening;
      case AssistantPhase.error:
      case AssistantPhase.idle:
        return '';
    }
  }

  static String _phaseLabelFor(
    AssistantPhase phase,
    S t, {
    VoiceErrorCode? errorCode,
  }) {
    switch (phase) {
      case AssistantPhase.connecting:
        return 'CONNECTING';
      case AssistantPhase.listening:
        return 'LISTENING';
      case AssistantPhase.thinking:
        return 'THINKING';
      case AssistantPhase.speaking:
        return 'SPEAKING';
      case AssistantPhase.error:
        // Append the failing stage when known so the driver sees
        // "ERROR · STT" (couldn't hear me — try again) vs.
        // "ERROR · TTS" (heard fine, can't reply audibly — read
        // the on-screen text) vs. "ERROR · NET" (network/backend
        // — retry once the indicator clears). Distinct retry
        // guidance beats a generic "Voice error".
        final tag = _errorStageTag[errorCode];
        return tag == null ? 'ERROR' : 'ERROR · $tag';
      case AssistantPhase.idle:
        return '';
    }
  }

  /// Short uppercase tag per error code for the phase chip. Keep
  /// each tag ≤ 4 chars so the chip width stays steady.
  static const _errorStageTag = <VoiceErrorCode, String>{
    VoiceErrorCode.sttFailed: 'STT',
    VoiceErrorCode.vadFailed: 'MIC',
    VoiceErrorCode.micPermissionDenied: 'PERM',
    // unknown intentionally absent — falls through to bare "ERROR".
  };

  static _Palette _paletteFor(AssistantPhase phase, ColorScheme cs) {
    switch (phase) {
      case AssistantPhase.listening:
        return const _Palette(AppColors.secondary);
      case AssistantPhase.thinking:
        return const _Palette(AppColors.warning);
      case AssistantPhase.speaking:
        return const _Palette(AppColors.accent);
      case AssistantPhase.error:
        return const _Palette(AppColors.warning);
      case AssistantPhase.connecting:
      case AssistantPhase.idle:
        return _Palette(cs.onSurfaceVariant);
    }
  }
}

class _Palette {
  const _Palette(this.color);
  final Color color;
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(120), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-phase visualiser:
///   * listening — amplitude bars driven by VAD dBFS
///   * thinking  — three pulsing dots (no real signal to react to)
///   * speaking  — pseudo-amplitude wave keyed off TTS playback rhythm
///   * else      — flat bars, dim
///
/// Single AnimationController repaints the bars at ~60 fps; the
/// dBFS provider only emits ~10 Hz, so without the local ticker the
/// bars would look choppy.
class _Visualiser extends StatefulWidget {
  const _Visualiser({
    required this.phase,
    required this.level,
    required this.color,
  });

  final AssistantPhase phase;
  final double level;
  final Color color;

  @override
  State<_Visualiser> createState() => _VisualiserState();
}

class _VisualiserState extends State<_Visualiser>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  // Smoothed amplitude — chases [widget.level] so bar heights ease
  // between dBFS samples instead of stepping every 100 ms.
  double _smoothed = 0;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _ticker.addListener(_tick);
  }

  void _tick() {
    final target = widget.level;
    // Asymmetric ease — fast attack so bars react instantly to a
    // loud syllable, slower release so they don't snap to silence
    // between syllables.
    final attack = target > _smoothed ? 0.35 : 0.08;
    final next = _smoothed + (target - _smoothed) * attack;
    if ((next - _smoothed).abs() > 0.001) {
      setState(() => _smoothed = next);
    }
  }

  @override
  void dispose() {
    _ticker.removeListener(_tick);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) {
        return CustomPaint(
          painter: _VisualiserPainter(
            phase: widget.phase,
            amplitude: _smoothed,
            phaseTime: _ticker.value,
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _VisualiserPainter extends CustomPainter {
  _VisualiserPainter({
    required this.phase,
    required this.amplitude,
    required this.phaseTime,
    required this.color,
  });

  final AssistantPhase phase;
  final double amplitude;
  final double phaseTime;
  final Color color;

  static const int _barCount = 5;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    switch (phase) {
      case AssistantPhase.thinking:
      case AssistantPhase.connecting:
        _paintDots(canvas, size);
      case AssistantPhase.listening:
      case AssistantPhase.speaking:
      case AssistantPhase.error:
      case AssistantPhase.idle:
        _paintBars(canvas, size);
    }
  }

  void _paintBars(Canvas canvas, Size size) {
    final barWidth = (size.width - _gap * (_barCount - 1)) / _barCount;
    final paint = Paint()..color = color;
    final cy = size.height / 2;
    for (var i = 0; i < _barCount; i++) {
      // Per-bar phase offset so the wave doesn't pulse in unison.
      final bias = math.sin((phaseTime * 2 * math.pi) + i * 0.6) * 0.5 + 0.5;
      // Speaking phase has no real input signal, so synthesise a
      // gentle wave that says "audio is playing" without a fake
      // amplitude reading.
      final base = phase == AssistantPhase.speaking
          ? 0.35 + bias * 0.55
          : 0.18 + amplitude * (0.55 + bias * 0.45);
      // Idle / error → low-flat baseline.
      final h = (phase == AssistantPhase.idle || phase == AssistantPhase.error)
          ? 0.2 * size.height
          : base.clamp(0.18, 1.0) * size.height;
      final x = i * (barWidth + _gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, cy - h / 2, barWidth, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  void _paintDots(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const dots = 3;
    final dotSize = size.height * 0.32;
    final spacing = (size.width - dotSize * dots) / (dots + 1);
    final cy = size.height / 2;
    for (var i = 0; i < dots; i++) {
      // Staggered scale so the trio breathes left-to-right.
      final t = (phaseTime + i / dots) % 1.0;
      final scale = 0.55 + (math.sin(t * 2 * math.pi) * 0.5 + 0.5) * 0.45;
      final r = (dotSize / 2) * scale;
      final cx = spacing + dotSize / 2 + i * (dotSize + spacing);
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VisualiserPainter old) =>
      old.phase != phase ||
      old.amplitude != amplitude ||
      old.phaseTime != phaseTime ||
      old.color != color;
}

/// Copy for each classified voice-error code. Ported from the
/// retired AssistantOverlay so error rendering stays identical;
/// kept module-scoped to avoid the AOT tree-shaking foot-gun the
/// old overlay's comment block called out.
const Map<VoiceErrorCode, String> _voiceErrorCopy = {
  VoiceErrorCode.sttFailed: "Couldn't hear you — speak clearly and try again",
  VoiceErrorCode.vadFailed: 'Mic glitch — tap mic again',
  VoiceErrorCode.micPermissionDenied: 'Mic permission off — open Settings',
  VoiceErrorCode.unknown: 'Voice error',
};
