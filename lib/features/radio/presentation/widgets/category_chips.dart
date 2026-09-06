import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/colors.dart';

/// Single chip-bar row used at the top of [RadioScreen]. Purely
/// presentational — state of which chip is selected lives in the parent
/// `RadioScreen` so category switching is a pure local-setState affair.
class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<CategoryChipItem> items;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = items[i];
          final selected = i == selectedIndex;
          return _Chip(
            label: item.label,
            icon: item.icon,
            selected: selected,
            onTap: () => onChanged(i),
          );
        },
      ),
    );
  }
}

class CategoryChipItem {
  const CategoryChipItem({required this.label, required this.icon});
  final String label;
  final IconData icon;
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final border = selected ? AppColors.accent : cs.outlineVariant;
    final bg = selected ? AppColors.accent.withAlpha(40) : cs.surfaceContainer;
    final fg = selected ? AppColors.accent : cs.onSurfaceVariant;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
