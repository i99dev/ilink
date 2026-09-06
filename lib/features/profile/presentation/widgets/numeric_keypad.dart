import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 3×4 grid matching standard phone keypads — digits 1–9 across three
/// rows, then a trailing row of [blank, 0, backspace]. Tall enough to
/// tap on the car head unit, compact enough for narrow Chrome windows.
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.disabled = false,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          _Row(
            children: [
              for (final d in row) _DigitKey(digit: d, onTap: _digitHandler(d)),
            ],
          ),
        _Row(
          children: [
            const _EmptyKey(),
            _DigitKey(digit: '0', onTap: _digitHandler('0')),
            _BackspaceKey(onTap: disabled ? null : onBackspace),
          ],
        ),
      ],
    );
  }

  VoidCallback? _digitHandler(String d) => disabled ? null : () => onDigit(d);
}

class _Row extends StatelessWidget {
  const _Row({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final c in children)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: c),
      ],
    ),
  );
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({required this.digit, required this.onTap});
  final String digit;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _KeyShell(
      onTap: onTap,
      child: Text(
        digit,
        style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),
    );
  }
}

class _BackspaceKey extends StatelessWidget {
  const _BackspaceKey({required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _KeyShell(
      onTap: onTap,
      child: Icon(
        Icons.backspace_outlined,
        color: cs.onSurfaceVariant,
        size: 24,
      ),
    );
  }
}

class _EmptyKey extends StatelessWidget {
  const _EmptyKey();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 72, height: 72);
}

class _KeyShell extends StatelessWidget {
  const _KeyShell({required this.onTap, required this.child});
  final VoidCallback? onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      radius: 44,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          shape: BoxShape.circle,
          border: Border.all(color: cs.outlineVariant),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
