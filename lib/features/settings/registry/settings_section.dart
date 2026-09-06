import 'package:flutter/material.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../themes/presentation/widgets/themes_section.dart';
import '../presentation/widgets/sections/about_section.dart';
import '../presentation/widgets/sections/appearance_section.dart';
import '../presentation/widgets/sections/cluster_safe_section.dart';
import '../presentation/widgets/sections/optional_services_section.dart';
import '../presentation/widgets/sections/language_section.dart';
import '../presentation/widgets/sections/models_section.dart';
import '../presentation/widgets/sections/privacy_section.dart';

/// Bag of mutable state owned by `SettingsPage` that individual sections
/// need to render (the in-flight `ModelsDraft`, dirty callback). Passed
/// into the registry `builder` so each section stays a dumb renderer
/// and the page remains the single source of truth.
class SettingsSectionContext {
  const SettingsSectionContext({
    required this.modelsDraft,
    required this.onChanged,
    required this.onDraftChange,
  });

  final ModelsDraft modelsDraft;
  final VoidCallback onChanged;
  final ValueChanged<ModelsDraft> onDraftChange;
}

typedef SettingsSectionBuilder =
    Widget Function(BuildContext context, SettingsSectionContext ctx);

/// Title/subtitle resolvers receive the current [S] so the rail/tabs can
/// stay in sync with the active locale. Built at call-time rather than
/// stored as plain strings so the registry doesn't need a BuildContext
/// at module load.
typedef SettingsSectionLabel = String Function(S t);

class SettingsSectionSpec {
  const SettingsSectionSpec({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String id;
  final SettingsSectionLabel title;
  final SettingsSectionLabel subtitle;
  final IconData icon;
  final SettingsSectionBuilder builder;
}

/// Fixed catalog of settings sections. Add a new section by adding one
/// entry — rail, tabs, and detail pane all read from this map.
///
/// Key order is iteration order (LinkedHashMap), so this also defines
/// the left-rail / top-tab ordering.
final Map<String, SettingsSectionSpec> settingsSectionRegistry = {
  'models': SettingsSectionSpec(
    id: 'models',
    title: (t) => t.sectionModelsTitle,
    subtitle: (t) => t.sectionModelsSubtitleShort,
    icon: Icons.auto_awesome_outlined,
    builder: (_, ctx) => ModelsSection(
      draft: ctx.modelsDraft,
      onChanged: ctx.onChanged,
      onDraftChange: ctx.onDraftChange,
    ),
  ),
  'language': SettingsSectionSpec(
    id: 'language',
    title: (t) => t.sectionLanguageTitle,
    subtitle: (t) => t.sectionLanguageSubtitleShort,
    icon: Icons.language,
    builder: (_, _) => const LanguageSection(),
  ),
  'appearance': SettingsSectionSpec(
    id: 'appearance',
    title: (t) => t.sectionAppearanceTitle,
    subtitle: (t) => t.sectionAppearanceSubtitleShort,
    icon: Icons.tune,
    builder: (_, _) => const AppearanceSection(),
  ),
  'themes': SettingsSectionSpec(
    id: 'themes',
    title: (t) => t.sectionThemesTitle,
    subtitle: (t) => t.sectionThemesSubtitleShort,
    icon: Icons.palette_outlined,
    builder: (_, _) => const ThemesSection(),
  ),
  'privacy': SettingsSectionSpec(
    id: 'privacy',
    title: (t) => t.sectionPrivacyTitle,
    subtitle: (t) => t.sectionPrivacySubtitleShort,
    icon: Icons.shield_outlined,
    builder: (_, _) => const PrivacySection(),
  ),
  'cluster': SettingsSectionSpec(
    id: 'cluster',
    title: (t) => t.sectionClusterTitle,
    subtitle: (t) => t.sectionClusterSubtitleShort,
    icon: Icons.speed,
    builder: (_, _) => const ClusterSafeSection(),
  ),
  // Nav-HUD moved OFF Settings — it now lives on the home Tools strip as the
  // "pin" circle (see kToolsRegistry → ToolKind.navHud → NavHudSheet), so
  // activation + config sit one tap from the dashboard, not buried in Settings.
  // Floating per-app shortcut buttons likewise live on the strip ("FAB" circle).
  // Integrations (third-party service connections). Labels are plain
  // strings (English-first section) rather than S keys to avoid an
  // l10n-gen cycle; localize later if it stays.
  'optionalServices': SettingsSectionSpec(
    id: 'optionalServices',
    title: (t) => 'Optional Services',
    subtitle: (t) => 'Connections you choose',
    icon: Icons.extension_outlined,
    builder: (_, _) => const OptionalServicesSection(),
  ),
  'about': SettingsSectionSpec(
    id: 'about',
    title: (t) => t.sectionAboutTitle,
    subtitle: (t) => t.sectionAboutSubtitleShort,
    icon: Icons.info_outline_rounded,
    builder: (_, _) => const AboutSection(),
  ),
};
