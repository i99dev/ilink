import 'package:flutter/material.dart';

import '../../domain/mini_app.dart';
import 'mini_app_remote_image.dart';
import 'mini_app_status_chips.dart';

/// Compact horizontal-row view of a [MiniApp]. Same data as [MiniAppTile]
/// but optimized for scanning many apps quickly:
///   icon | name + category + chips | trailing action
///
/// Used by the List view-mode in the mini-apps screen. Tap behaviour and
/// trailing widget come from the caller so Store-mode rows can show
/// Install while My-Apps rows show Pin / launch on tap.
class MiniAppListRow extends StatelessWidget {
  const MiniAppListRow({
    super.key,
    required this.app,
    required this.languageCode,
    this.onTap,
    this.onLongPress,
    this.trailing,
  });

  final MiniApp app;
  final String languageCode;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = app.localizedName(languageCode);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          app.category,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: MiniAppStatusChips(app: app, dense: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

class _Icon extends StatelessWidget {
  const _Icon({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 44,
        height: 44,
        child: MiniAppRemoteImage(url: url),
      ),
    );
  }
}
