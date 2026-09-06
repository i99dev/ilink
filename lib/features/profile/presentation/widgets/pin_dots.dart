import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/colors.dart';

class PinDots extends StatelessWidget {
  const PinDots({
    super.key,
    required this.length,
    required this.filled,
    this.errorState = false,
  });

  final int length;
  final int filled;
  final bool errorState;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = errorState ? AppColors.error : AppColors.accent;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? activeColor : cs.surfaceContainerHigh,
                border: Border.all(
                  color: i < filled ? activeColor : cs.outlineVariant,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
