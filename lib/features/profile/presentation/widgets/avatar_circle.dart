import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/colors.dart';

/// Compact avatar primitive — renders, in preference order:
///   1. The Telegram photo at [imageUrl] when set (matches the
///      website's [UserAvatar] cascade so the marketing site, the
///      Telegram mini-app, and the in-car Profile show the same face).
///   2. [initials] on an accent ring when non-empty.
///   3. A person icon when both are missing (guest state).
///
/// Image load errors gracefully fall back to (2)/(3) via
/// [Image.network]'s [errorBuilder] — Telegram CDN URLs expire after
/// ~1h, so a stale URL must not break the avatar.
///
/// Kept const-constructible so Riverpod rebuilds of the parent don't
/// re-inflate this subtree.
class AvatarCircle extends StatelessWidget {
  const AvatarCircle({
    super.key,
    this.initials = '',
    this.imageUrl,
    this.size = 36,
    this.ringColor,
    this.showRing = true,
  });

  final String initials;

  /// Optional remote image to display in place of [initials]. When the
  /// load fails (404, expired Telegram URL, offline) the widget falls
  /// through to the initials/icon path silently.
  final String? imageUrl;

  final double size;
  final Color? ringColor;
  final bool showRing;

  bool get _isGuest =>
      initials.isEmpty && (imageUrl == null || imageUrl!.isEmpty);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ring = ringColor ?? (_isGuest ? cs.outline : AppColors.accent);
    final fill = _isGuest ? cs.surfaceContainerHigh : cs.surfaceContainer;
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    final fallback = initials.isEmpty
        ? Icon(
            Icons.person_outline,
            size: size * 0.55,
            color: cs.onSurfaceVariant,
          )
        : Text(
            initials,
            style: TextStyle(
              fontSize: size * 0.38,
              fontWeight: FontWeight.w700,
              color: ring,
              letterSpacing: 0.5,
            ),
          );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: showRing
            ? Border.all(color: ring.withAlpha(_isGuest ? 80 : 200), width: 1.5)
            : null,
      ),
      alignment: Alignment.center,
      clipBehavior: hasImage ? Clip.antiAlias : Clip.none,
      child: fallback,
    );
  }
}
