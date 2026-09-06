import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../features/_car_domain/command/command_outcome.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../sdk/car/client.dart';

// Per-window controls. UnitDispatcher window values:
// 0=stop, 1=open(down), 2=close(up), 3=full down.
class WindowsPanel extends ConsumerWidget {
  const WindowsPanel({super.key, required this.onResult});
  final void Function(String) onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.windows, style: _labelStyle(cs)),
            const SizedBox(height: 10),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: _row(ref, t.windowDriver, 'fl', cs)),
                  const SizedBox(height: 6),
                  Expanded(child: _row(ref, t.windowPassenger, 'rf', cs)),
                  const SizedBox(height: 6),
                  Expanded(child: _row(ref, t.windowRearLeft, 'rl', cs)),
                  const SizedBox(height: 6),
                  Expanded(child: _row(ref, t.windowRearRight, 'rr', cs)),
                  const SizedBox(height: 6),
                  Expanded(child: _row(ref, t.windowSunroof, 'sr', cs)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(WidgetRef ref, String label, String side, ColorScheme cs) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        Expanded(
          child: _btn(ref, side, 2, Icons.arrow_upward, AppColors.secondary),
        ),
        const SizedBox(width: 6),
        Expanded(child: _btn(ref, side, 0, Icons.pause, AppColors.warning)),
        const SizedBox(width: 6),
        Expanded(
          child: _btn(ref, side, 1, Icons.arrow_downward, AppColors.accent),
        ),
      ],
    );
  }

  Widget _btn(
    WidgetRef ref,
    String side,
    int value,
    IconData icon,
    Color color,
  ) {
    return _WindowBtn(
      icon: icon,
      color: color,
      onTap: () async {
        final actionId = switch (side) {
          'fl' => 'window.fl',
          'rf' => 'window.rf',
          'rl' => 'window.rl',
          'rr' => 'window.rr',
          // sunroof.ctl is a VERB enum (0=stop/1=open/2=close/3=tilt) — the
          // same 0/1/2 the buttons send. (Regression #114 wired this to
          // sunroof.percent, which expects 0–100, so "open" sent 1% → dead.)
          'sr' => 'sunroof.ctl',
          _ => 'window.fl',
        };
        final raw = await ref
            .read(carClientProvider)
            .dispatch(actionId, args: {'value': value});
        final out = CommandOutcome.fromBridge(raw.cast<String, dynamic>());
        onResult(out.describe('window $side=$value'));
        return out.ok;
      },
    );
  }
}

// Slim tile tuned for the WindowsPanel row (height ~36).
class _WindowBtn extends StatefulWidget {
  const _WindowBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final Future<bool> Function() onTap;
  @override
  State<_WindowBtn> createState() => _WindowBtnState();
}

class _WindowBtnState extends State<_WindowBtn> {
  bool _pressed = false;
  int _flash = 0; // 0=none, 1=pending, 2=ok, 3=err

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final border = switch (_flash) {
      1 => AppColors.secondary,
      2 => AppColors.accent,
      3 => AppColors.error,
      _ => cs.outlineVariant,
    };
    final iconColor = switch (_flash) {
      1 => AppColors.secondary,
      2 => AppColors.accent,
      3 => AppColors.error,
      _ => widget.color,
    };
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () async {
        setState(() {
          _pressed = false;
          _flash = 1;
        });
        bool ok = false;
        try {
          ok = await widget.onTap();
        } catch (_) {}
        if (!mounted) return;
        setState(() => _flash = ok ? 2 : 3);
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted) setState(() => _flash = 0);
        });
      },
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Center(child: Icon(widget.icon, size: 18, color: iconColor)),
        ),
      ),
    );
  }
}

TextStyle _labelStyle(ColorScheme cs) => TextStyle(
  fontSize: 10,
  color: cs.onSurfaceVariant,
  letterSpacing: 2,
  fontWeight: FontWeight.w600,
);
