import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/settings/app_settings.dart';
import '../../../../kernel/ui/theme/colors.dart';
import '../../../mini_apps/presentation/widgets/mini_app_remote_image.dart';
import '../../../settings/presentation/widgets/section_scaffold.dart';
import '../../data/built_in_themes.dart';
import '../../domain/theme_item.dart';
import '../../state/theme_providers.dart';
import 'theme_swatch.dart';

/// Settings → Themes gallery. Lists the bundled built-in themes plus
/// any catalog themes, each with a palette-swatch / cover preview and an
/// Apply action that persists `AppSettings.activeThemeId`. The active
/// row is marked. Applying re-themes the whole shell live (no restart)
/// via `activeThemeDataProvider` in `main.dart`.
class ThemesSection extends ConsumerWidget {
  const ThemesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final catalog = ref.watch(themeCatalogProvider);
    return SectionScaffold(
      title: t.sectionThemesTitle,
      subtitle: t.sectionThemesSubtitleShort,
      child: catalog.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        ),
        // The repository degrades to built-ins on any transport error, so
        // a hard AsyncError here is rare (parse/merge bug). Still render
        // a friendly message rather than a red box.
        error: (_, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              t.themesLoadError,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        data: (themes) {
          if (themes.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  t.themesEmpty,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.themesGalleryHeader,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              for (final theme in themes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _ThemeCard(
                    theme: theme,
                    languageCode: lang,
                    onApply: () => _apply(ref, theme.id),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Persist the chosen theme id. The built-in dark theme maps back to
  /// the empty sentinel so "Midnight" and "no theme selected" stay the
  /// same stored state (the inert default) — re-tapping the active row
  /// is a no-op.
  void _apply(WidgetRef ref, String id) {
    final s = ref.read(settingsProvider).value;
    if (s == null) return;
    final nextId = id == kMidnightThemeId ? '' : id;
    if (s.activeThemeId == nextId) return;
    ref.read(settingsProvider.notifier).save(s.copyWith(activeThemeId: nextId));
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.languageCode,
    required this.onApply,
  });

  final ThemeItem theme;
  final String languageCode;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final active = theme.isActive;
    final name = theme.localizedName(languageCode);
    final description = theme.localizedDescription(languageCode);
    return InkWell(
      onTap: active ? null : onApply,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview: cover image when the catalog ships one, else the
            // theme's own palette swatch (always available, offline).
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child:
                    (theme.coverImage != null && theme.coverImage!.isNotEmpty)
                    ? MiniAppRemoteImage(
                        url: theme.coverImage,
                        fallback: ThemeSwatch(spec: theme.spec),
                      )
                    : ThemeSwatch(spec: theme.spec),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: TextStyle(
                            color: active ? AppColors.accent : cs.onSurface,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (theme.isBuiltIn) ...[
                        const SizedBox(width: 8),
                        _Pill(label: t.themesBuiltInLabel, color: cs.outline),
                      ],
                      if (theme.isBeta) ...[
                        const SizedBox(width: 8),
                        _Pill(
                          label: t.themesBetaLabel,
                          color: AppColors.warning,
                        ),
                      ],
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (active)
              Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: AppColors.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    t.themesActiveLabel,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              )
            else
              OutlinedButton(
                onPressed: onApply,
                child: Text(t.themesApplyButton),
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
