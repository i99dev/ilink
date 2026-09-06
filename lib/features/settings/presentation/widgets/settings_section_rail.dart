import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../registry/settings_section.dart';

/// Left rail used on expanded/ultrawide. On compact, the parent uses
/// [SettingsSectionTabs] instead. Both walk [settingsSectionRegistry].
class SettingsSectionRail extends StatelessWidget {
  const SettingsSectionRail({
    super.key,
    required this.currentId,
    required this.onSelect,
  });

  final String currentId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 260,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(right: BorderSide(color: cs.outlineVariant)),
      ),
      child: ListView(
        children: [
          for (final spec in settingsSectionRegistry.values)
            _RailTile(
              spec: spec,
              active: spec.id == currentId,
              onTap: () => onSelect(spec.id),
            ),
        ],
      ),
    );
  }
}

class _RailTile extends StatelessWidget {
  const _RailTile({
    required this.spec,
    required this.active,
    required this.onTap,
  });
  final SettingsSectionSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final color = active ? AppColors.accent : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: active ? AppColors.accent.withAlpha(28) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? AppColors.accent : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(spec.icon, color: color, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec.title(t),
                      style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      spec.subtitle(t),
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Top-bar tab presentation used on compact layouts. Walks the same
/// [settingsSectionRegistry] so state flows identically regardless of layout.
class SettingsSectionTabs extends StatelessWidget {
  const SettingsSectionTabs({
    super.key,
    required this.currentId,
    required this.onSelect,
  });

  final String currentId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final spec in settingsSectionRegistry.values) ...[
            _TabChip(
              spec: spec,
              active: spec.id == currentId,
              onTap: () => onSelect(spec.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.spec,
    required this.active,
    required this.onTap,
  });
  final SettingsSectionSpec spec;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final c = active ? AppColors.accent : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(100),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(spec.icon, color: c, size: 16),
            const SizedBox(width: 6),
            Text(
              spec.title(t),
              style: TextStyle(
                color: c,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
