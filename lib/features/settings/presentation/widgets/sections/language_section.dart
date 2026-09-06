import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/ui/theme/colors.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../../kernel/i18n/locale_controller.dart';
import '../section_scaffold.dart';

/// Same language-picker affordance as the legacy page, just relocated into
/// the master-detail shell and wrapped in a [SectionScaffold].
class LanguageSection extends ConsumerWidget {
  const LanguageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final current =
        ref.watch(localeControllerProvider.select((a) => a.value)) ??
        AppLang.en;
    return SectionScaffold(
      title: t.sectionLanguageTitle,
      subtitle: t.sectionLanguageSubtitleShort,
      child: Column(
        children: [
          for (final l in AppLang.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _LangRow(
                lang: l,
                active: l == current,
                onTap: () => ref.read(localeControllerProvider.notifier).set(l),
              ),
            ),
        ],
      ),
    );
  }
}

class _LangRow extends StatelessWidget {
  const _LangRow({
    required this.lang,
    required this.active,
    required this.onTap,
  });
  final AppLang lang;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = active ? AppColors.accent : cs.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Text(
              lang.label,
              style: TextStyle(
                color: c,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (active)
              const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
