import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../sdk/car/providers.dart';

/// Tile with built-in press feedback:
///  - scales to 0.93 on pointer-down, springs back on release
///  - after [markResult] is called, the icon + border pulse
///    teal (ok) or coral (failed) for 700ms before returning to idle
///
/// Use the [stateKey] GlobalKey pattern to drive [markResult] from the
/// parent once a command resolves.
class PressableTile extends ConsumerStatefulWidget {
  const PressableTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.enabled = true,
    this.wide = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Future<bool> Function() onTap;
  final bool enabled;
  final bool wide;
  final bool compact;

  @override
  ConsumerState<PressableTile> createState() => _PressableTileState();
}

class _PressableTileState extends ConsumerState<PressableTile>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  _Flash _flash = _Flash.none;

  Future<void> _run() async {
    if (!widget.enabled) return;
    // If daemon isn't up yet, show a warm-up flash instead of firing —
    // prevents the user from sending taps into the void during startup.
    final ready = ref
        .read(daemonReadyProvider)
        .maybeWhen(data: (v) => v, orElse: () => false);
    if (!ready) {
      setState(() => _flash = _Flash.pending);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _flash = _Flash.none);
      });
      return;
    }
    // Optimistic: show a neutral "pending" pulse immediately so the user
    // feels the tap even before the command resolves.
    setState(() => _flash = _Flash.pending);
    bool ok = false;
    try {
      ok = await widget.onTap();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _pressed = false;
      _flash = ok ? _Flash.ok : _Flash.err;
    });
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _flash = _Flash.none);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final flashColor = switch (_flash) {
      _Flash.ok => AppColors.accent,
      _Flash.err => AppColors.error,
      _Flash.pending => AppColors.secondary,
      _Flash.none => Colors.transparent,
    };
    final iconColor = widget.enabled
        ? switch (_flash) {
            _Flash.ok => AppColors.accent,
            _Flash.err => AppColors.error,
            _Flash.pending => AppColors.secondary,
            _Flash.none => widget.color,
          }
        : cs.onSurfaceVariant;
    final borderColor = _flash == _Flash.none
        ? cs.outlineVariant
        : flashColor.withAlpha(180);

    return GestureDetector(
      onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _run,
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: borderColor,
              width: _flash == _Flash.none ? 1 : 1.5,
            ),
            boxShadow: _flash == _Flash.none
                ? null
                : [
                    BoxShadow(
                      color: flashColor.withAlpha(60),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
          ),
          child: widget.wide
              ? _wideLayout(iconColor, cs)
              : _squareLayout(iconColor, cs),
        ),
      ),
    );
  }

  Widget _squareLayout(Color iconColor, ColorScheme cs) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Container(
        width: widget.compact ? 40 : 56,
        height: widget.compact ? 40 : 56,
        decoration: BoxDecoration(
          color: iconColor.withAlpha(28),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          widget.icon,
          color: iconColor,
          size: widget.compact ? 22 : 28,
        ),
      ),
      SizedBox(height: widget.compact ? 6 : 10),
      Text(
        widget.label,
        style: TextStyle(
          fontSize: widget.compact ? 10 : 11,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
          color: widget.enabled ? cs.onSurfaceVariant : cs.outline,
        ),
      ),
    ],
  );

  Widget _wideLayout(Color iconColor, ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(
      children: [
        Icon(widget.icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    ),
  );
}

enum _Flash { none, pending, ok, err }
