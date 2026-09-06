import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../../features/_car_domain/ui/vehicle_support_badge.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../../kernel/settings/app_settings.dart';
import '../../../../../kernel/services/optional_services.dart';
import '../../../../../app/update/update_controller.dart';
import '../../../../../app/update/update_orchestrator.dart';
import '../../../../../app/update/update_state.dart';
import '../../pages/diagnostics_page.dart';
import '../section_scaffold.dart';

class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _info = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final info = _info;
    final rows = <_InfoRow>[
      _InfoRow(label: t.aboutAppName, value: info?.appName ?? '—'),
      _InfoRow(
        label: t.aboutVersion,
        value: info == null ? '—' : '${info.version} (${info.buildNumber})',
        copyable: true,
      ),
      _InfoRow(label: t.aboutPackage, value: info?.packageName ?? '—'),
      _InfoRow(
        label: t.aboutDevelopedBy,
        value: t.aboutDevelopedByValue,
        logo: const _CubeTekLogo(),
      ),
      _InfoRow(
        label: t.aboutSponsoredBy,
        value: t.aboutSponsoredByValue,
        logo: const _QevLogo(),
      ),
    ];
    final updateState = ref.watch(updateControllerProvider).value;
    final isChecking = updateState is UpdateChecking;
    final isUpdateBusy =
        isChecking ||
        updateState is UpdateDownloading ||
        updateState is UpdateReadyToInstall ||
        updateState is UpdateInstalling;
    return SectionScaffold(
      title: t.sectionAboutTitle,
      subtitle: t.sectionAboutSubtitleShort,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.4).clamp(
              160.0,
              360.0,
            ),
            child: const _BrandingHero(),
          ),
          const SizedBox(height: 16),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _InfoRowTile(row: r),
            ),
          // Vehicle-support tier — single line under the build-info
          // rows so the user immediately sees "what iLINK can do
          // on this car" without drilling into Diagnostics.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    t.vehicleSupportLabel,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Expanded(child: VehicleSupportBadge()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // An explicit check bypasses automatic prompt cooldown and idle gates.
          FilledButton.icon(
            onPressed: isUpdateBusy
                ? null
                : () async {
                    if (!ref.read(
                      serviceEnabledProvider(OptionalService.updates),
                    )) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Text(
                            const ServiceDisabled(
                              OptionalService.updates,
                            ).toString(),
                          ),
                        ),
                      );
                      return;
                    }
                    final controller = ref.read(
                      updateControllerProvider.notifier,
                    );
                    await controller.check();
                    // The check can take 5-15s on flaky cellular; if the
                    // user navigated away from Settings in that window,
                    // `ref` is unsafe to use.
                    if (!mounted) return;
                    final next = ref.read(updateControllerProvider).value;
                    if (next is UpdateAvailable) {
                      ref.read(promptUpdateProvider.notifier).value = next;
                    } else if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 3),
                          content: Text(t.aboutCheckUpToDate),
                        ),
                      );
                    }
                  },
            icon: isChecking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt_rounded, size: 18),
            label: Text(t.aboutCheckForUpdates),
          ),
          const SizedBox(height: 8),
          // Diagnostics drilldown — app/build environment +
          // launcher-mode privilege grid. Always visible (not gated
          // on Dev mode) so support engineers + the user can read
          // current HU state without flipping any feature flags.
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
            ),
            icon: const Icon(Icons.medical_information_outlined, size: 18),
            label: Text(t.aboutOpenDiagnostics),
          ),
          const SizedBox(height: 12),
          // Flight Test (beta) opt-in — surfaced here on About so testers
          // can turn on the beta tab without the Developer section being
          // visible. Independent toggle; the worst case is "an extra
          // empty tab appears" so there's no confirm dialog.
          const _FlightTestToggle(),
        ],
      ),
    );
  }
}

/// Flight Test mode switch — shows/hides the beta ("Flight Test") tab in
/// the mini-apps store. Lives on About (not just the hidden Developer
/// section) so invited testers can opt in.
class _FlightTestToggle extends ConsumerWidget {
  const _FlightTestToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final on = ref.watch(
      settingsProvider.select((a) => a.value?.flightTestModeEnabled ?? false),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.devFlightTestModeLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.devFlightTestModeSub,
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: on,
            onChanged: (next) {
              final current =
                  ref.read(settingsProvider).value ?? AppSettings.empty;
              ref
                  .read(settingsProvider.notifier)
                  .save(current.copyWith(flightTestModeEnabled: next));
            },
          ),
        ],
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow({
    required this.label,
    required this.value,
    this.copyable = false,
    this.logo,
  });
  final String label;
  final String value;
  final bool copyable;

  final Widget? logo;
}

class _InfoRowTile extends StatelessWidget {
  const _InfoRowTile({required this.row});
  final _InfoRow row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (row.logo != null) ...[
                      row.logo!,
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: SelectableText(
                        row.value,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontFamily: row.copyable ? 'monospace' : null,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (row.copyable)
            IconButton(
              tooltip: S.of(context).aboutCopy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: row.value));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                    content: Text(S.of(context).aboutCopied),
                  ),
                );
              },
              icon: const Icon(Icons.content_copy_rounded, size: 18),
            ),
        ],
      ),
    );
  }
}

class _BrandingHero extends StatelessWidget {
  const _BrandingHero();

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _BrandingHeroTile(
            roleLabel: t.aboutDevelopedBy,
            brandName: t.aboutDevelopedByValue,
            child: const _CubeTekLogo(large: true),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _BrandingHeroTile(
            roleLabel: t.aboutSponsoredBy,
            brandName: t.aboutSponsoredByValue,
            child: const _QevLogo(large: true),
          ),
        ),
      ],
    );
  }
}

class _BrandingHeroTile extends StatelessWidget {
  const _BrandingHeroTile({
    required this.roleLabel,
    required this.brandName,
    required this.child,
  });

  final String roleLabel;
  final String brandName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Center(child: child)),
          const SizedBox(height: 12),
          Text(
            roleLabel.toUpperCase(),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            brandName,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// CubeTek wordmark logo. The source SVG paints with
/// ``fill: currentColor`` so the rendered glyph picks up whatever
/// [Theme.of(context).colorScheme.onSurface] resolves to — the mark
/// stays legible across light + dark mode without shipping two
/// raster variants.
class _CubeTekLogo extends StatelessWidget {
  const _CubeTekLogo({this.large = false});

  /// `false` (default) renders the 18px inline row variant. `true`
  /// fills its parent slot for the about-page hero.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final svg = SvgPicture.asset(
      'assets/branding/cubetek.svg',
      height: large ? null : 18,
      fit: large ? BoxFit.contain : BoxFit.contain,
      colorFilter: ColorFilter.mode(cs.onSurface, BlendMode.srcIn),
      semanticsLabel: 'CubeTek',
    );
    return large ? FittedBox(fit: BoxFit.contain, child: svg) : svg;
  }
}

/// QEV crest logo. Raster artwork with its own brand palette
/// (silver / blue gradient, dark navy circuit-board background) —
/// rendered as-shipped without a tint so the brand reads identically
/// to the marketing site. Constrained to the same 18px row height as
/// the CubeTek wordmark for visual rhythm.
class _QevLogo extends StatelessWidget {
  const _QevLogo({this.large = false});

  /// `false` (default) renders the 24px inline row variant. `true`
  /// fills its parent slot for the about-page hero.
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (large) {
      // Hero — let it expand to the hero tile's centred slot while
      // keeping the brand's native aspect ratio (the crest is roughly
      // square).
      return AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset('assets/branding/qev.jpg', fit: BoxFit.cover),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.asset(
        'assets/branding/qev.jpg',
        height: 24,
        width: 24,
        fit: BoxFit.cover,
      ),
    );
  }
}
