import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/locale_controller.dart';
import '../../state/onboarding_controller.dart';

/// Two-pill locale toggle. Tapping a pill calls
/// `OnboardingController.setLocale`, which writes through the existing
/// `localeControllerProvider` — the entire app rebuilds in the new
/// locale immediately, demonstrating the toggle works without making
/// the user reach Settings.
class OnboardingLocalePicker extends ConsumerWidget {
  const OnboardingLocalePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      localeControllerProvider.select(
        (a) => a.value?.locale.languageCode ?? 'en',
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final lang in AppLang.values)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: _Pill(
              label: lang.label,
              active: current == lang.locale.languageCode,
              onTap: () => ref
                  .read(onboardingControllerProvider.notifier)
                  .setLocale(lang),
            ),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
            width: active ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? AppColors.accent : cs.onSurfaceVariant,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}
