import '../mini_app_install_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/i18n/locale_controller.dart';
import '../../domain/mini_app.dart';
import '../../state/mini_app_install_gate.dart';
import '../install_feedback.dart';
import '../launch_mini_app.dart';
import 'mini_app_remote_image.dart';
import 'mini_app_status_chips.dart';

/// Tap-to-details modal for a [MiniApp].
///
/// Shows:
///   * Header — icon + name + category + status chip strip.
///   * Description — multi-line localized prose.
///   * Technical metadata — id, version, host requirement, bundle hash
///     prefix. Useful for the "what is this thing actually" question.
///   * Single CTA — Install / Launch / Uninstall, depending on state.
///
/// Mounted via [showMiniAppDetails]. Long-press on a tile still goes
/// to the destructive uninstall confirm — those two flows are kept
/// separate so a long-press by accident doesn't open a busy dialog.
Future<void> showMiniAppDetails(
  BuildContext context,
  WidgetRef ref,
  MiniApp app, {
  required String languageCode,
}) {
  final theme = Theme.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: _MiniAppDetailsContent(app: app, languageCode: languageCode),
      ),
    ),
  );
}

class _MiniAppDetailsContent extends ConsumerWidget {
  const _MiniAppDetailsContent({required this.app, required this.languageCode});

  final MiniApp app;
  final String languageCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = S.of(context);
    final lang =
        ref.watch(
          localeControllerProvider.select((a) => a.value?.locale.languageCode),
        ) ??
        languageCode;
    final name = app.localizedName(lang);
    final description = app.localizedDescription(lang);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────
          Row(
            children: [
              _Icon(url: app.icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${app.category} · v${app.version}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                    const SizedBox(height: 8),
                    MiniAppStatusChips(app: app),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: S.of(context).actionClose,
              ),
            ],
          ),

          const SizedBox(height: 20),
          Divider(color: cs.outlineVariant.withAlpha(80), height: 1),

          // ── Body — scrollable ─────────────────────────────────
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cover banner — wide hero rendered above the
                  // description. Optional; collapses entirely when the
                  // publisher hasn't supplied one.
                  if ((app.coverImage ?? '').isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _CoverBanner(url: app.coverImage!),
                  ],
                  // Screenshot gallery — pre-install peek so the user
                  // sees what they're about to download. Tap to zoom.
                  if (app.screenshots.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const _SectionLabel(label: 'Screenshots'),
                    const SizedBox(height: 8),
                    _Screenshots(urls: app.screenshots),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const _SectionLabel(label: 'Description'),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ],
                  // Flight-test release notes — visible only when the app
                  // is on the beta track AND the developer attached notes
                  // via `sdk beta promote --notes "…"`. The same field
                  // already powers BetaConsentSheet on launch; here we
                  // surface it pre-install so testers can decide before
                  // committing to the install.
                  if (app.isBeta &&
                      (app.releaseNotes ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _SectionLabel(label: t.miniAppsFlightTestReleaseNotesTitle),
                    const SizedBox(height: 6),
                    Text(
                      app.releaseNotes!.trim(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const _SectionLabel(label: 'Technical'),
                  const SizedBox(height: 6),
                  _TechRow(label: 'ID', value: app.id),
                  _TechRow(label: 'Version', value: app.version),
                  _TechRow(
                    label: 'Min host',
                    value: app.minHostVersion.isEmpty
                        ? '—'
                        : app.minHostVersion,
                  ),
                  if (app.bundleSha256.isNotEmpty)
                    _TechRow(
                      label: 'Bundle SHA',
                      // 12 hex chars is enough to eyeball-compare
                      // without overwhelming the row width.
                      value: '${app.bundleSha256.substring(0, 12)}…',
                      monospace: true,
                    ),
                  if (app.privileged)
                    const _TechRow(
                      label: 'Install path',
                      value: 'Privileged (cert + cap verified)',
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),
          Divider(color: cs.outlineVariant.withAlpha(80), height: 1),
          const SizedBox(height: 12),

          // ── CTA row ───────────────────────────────────────────
          Row(
            children: [
              if (app.isInstalled) ...[
                _CtaButton.outlined(
                  label: t.miniAppsUninstall,
                  onPressed: () => _onUninstall(context, ref, app),
                ),
                const SizedBox(width: 8),
                _CtaButton.filled(
                  label: 'Launch',
                  icon: Icons.play_arrow_rounded,
                  onPressed: () {
                    Navigator.of(context).pop();
                    openMiniApp(context, ref, app);
                  },
                ),
              ] else ...[
                _CtaButton.filled(
                  label: t.miniAppsInstall,
                  icon: app.privileged
                      ? Icons.lock_outline_rounded
                      : Icons.download_rounded,
                  onPressed: () => _onInstall(context, ref, app),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(S.of(context).actionClose),
              ),
            ],
          ),
          // Build identifier — beta-track only. Tester quotes this
          // verbatim when reporting issues; 8-hex-char SHA prefix is
          // enough to disambiguate against the developer's announcement
          // without overwhelming the row width.
          if (app.isBeta && app.bundleSha256.length >= 8) ...[
            const SizedBox(height: 8),
            Text(
              t.miniAppsBuildIdentifier(
                app.version,
                app.bundleSha256.substring(0, 8),
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.outline,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _onInstall(
    BuildContext context,
    WidgetRef ref,
    MiniApp app,
  ) async {
    if (!await confirmMiniAppInstall(context, ref, app.id) ||
        !context.mounted) {
      return;
    }
    final navigator = Navigator.of(context);
    final outcome = await ref
        .read(miniAppInstallGateProvider)
        .install(caller: DetailsModalInstaller.instance, appId: app.id);
    if (!context.mounted) return;
    final hadError = showInstallOutcomeSnack(context, outcome);
    if (!hadError && navigator.canPop()) navigator.pop();
  }

  Future<void> _onUninstall(
    BuildContext context,
    WidgetRef ref,
    MiniApp app,
  ) async {
    final t = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.miniAppsUninstall),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.sessionEndedDismiss),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.miniAppsUninstall),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (confirmed == true) {
      final outcome = await ref
          .read(miniAppInstallGateProvider)
          .uninstall(caller: DetailsModalInstaller.instance, appId: app.id);
      if (!context.mounted) return;
      final hadError = showInstallOutcomeSnack(context, outcome);
      if (!hadError) Navigator.of(context).pop();
    }
  }
}

class _Icon extends StatelessWidget {
  const _Icon({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 64,
        height: 64,
        child: MiniAppRemoteImage(url: url),
      ),
    );
  }
}

/// Pre-install hero banner shown above the description in
/// [_MiniAppDetailsContent]. Fixed 16:9 aspect-ratio so the layout
/// reserves the same space whether the publisher supplies a banner
/// or not — collapsing the section would jolt the description down
/// after the network call resolves.
class _CoverBanner extends StatelessWidget {
  const _CoverBanner({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: MiniAppRemoteImage(url: url),
      ),
    );
  }
}

/// Horizontal screenshot strip. Each thumbnail is a square; tapping
/// opens a fullscreen viewer with pinch-zoom (`InteractiveViewer`).
class _Screenshots extends StatelessWidget {
  const _Screenshots({required this.urls});
  final List<String> urls;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final url = urls[i];
          return GestureDetector(
            onTap: () => _openFullscreen(ctx, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: MiniAppRemoteImage(url: url, fit: BoxFit.cover),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openFullscreen(BuildContext context, String url) {
    Navigator.of(context).push<void>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, _, _) => _ScreenshotViewer(url: url),
      ),
    );
  }
}

class _ScreenshotViewer extends StatelessWidget {
  const _ScreenshotViewer({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: InteractiveViewer(
            // Pinch-zoom up to 4x — head-unit screens are dense, so a
            // tap-to-zoom is more useful than scrolling between
            // multiple resolutions.
            maxScale: 4,
            child: MiniAppRemoteImage(url: url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.outline,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _TechRow extends StatelessWidget {
  const _TechRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });
  final String label;
  final String value;
  final bool monospace;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CtaButton extends StatelessWidget {
  const _CtaButton._({
    required this.label,
    required this.onPressed,
    required this.kind,
    this.icon,
  });
  factory _CtaButton.filled({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
  }) => _CtaButton._(
    label: label,
    onPressed: onPressed,
    kind: _CtaKind.filled,
    icon: icon,
  );
  factory _CtaButton.outlined({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
  }) => _CtaButton._(
    label: label,
    onPressed: onPressed,
    kind: _CtaKind.outlined,
    icon: icon,
  );

  final String label;
  final VoidCallback onPressed;
  final _CtaKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
        Text(label),
      ],
    );
    return kind == _CtaKind.filled
        ? FilledButton(onPressed: onPressed, child: child)
        : OutlinedButton(onPressed: onPressed, child: child);
  }
}

enum _CtaKind { filled, outlined }
