import 'package:flutter/material.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../domain/mini_app.dart';
import 'mini_app_remote_image.dart';

/// Shared card chrome for Store + My Apps grids. The wrapper is
/// responsible for tap behaviour (launch, open details); this widget
/// only renders icon + name + category + optional badges, and an
/// optional trailing [primary] widget (e.g., an Install button).
///
/// [betaBadge] is an optional widget (typically a [BetaBadge]) that
/// renders between the category label and the primary action. Pass it
/// when `app.isBeta` is true; the tile renders it in place of (or
/// alongside) the safe-while-driving badge.
///
/// Separating the chrome keeps both grids visually consistent without
/// duplicating the layout math, and leaves the tap-target shape in the
/// caller so Store-mode tiles can be non-launching (`onTap: null`)
/// while My-Apps tiles launch immediately.
class MiniAppTile extends StatelessWidget {
  const MiniAppTile({
    super.key,
    required this.app,
    required this.languageCode,
    this.onTap,
    this.onLongPress,
    this.primary,
    this.betaBadge,
  });

  final MiniApp app;
  final String languageCode;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? primary;

  /// Optional BETA pill widget. When non-null, rendered below the
  /// category label. Typically a [BetaBadge] from
  /// `beta_consent_sheet.dart`.
  final Widget? betaBadge;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final theme = Theme.of(context);
    final name = app.localizedName(languageCode);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconBox(url: app.icon),
              const SizedBox(height: 12),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                app.category,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  letterSpacing: 0.2,
                ),
              ),
              if (app.safeWhileDriving) ...[
                const SizedBox(height: 6),
                _SafeBadge(label: t.miniAppsSafeWhileDrivingBadge),
              ],
              if (betaBadge != null) ...[const SizedBox(height: 6), betaBadge!],
              const Spacer(),
              if (primary != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 56,
        height: 56,
        // Centralised SVG-aware loader; see mini_app_remote_image.dart
        // for the SVG-routing rationale.
        child: MiniAppRemoteImage(url: url),
      ),
    );
  }
}

class _SafeBadge extends StatelessWidget {
  const _SafeBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
