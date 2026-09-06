import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Reusable circular app-icon tile. One widget renders the icon
/// shape across every surface that displays an app:
///
///   * Apps tab tiles (`installed_apps_strip.dart`)
///   * Mini-apps favourite tiles (`favorite_mini_apps_strip.dart`)
///   * Running-app chips inside the DISPLAYS picker (`running_app_chip.dart`)
///
/// Three call sites used to roll their own `Container(decoration:
/// BoxDecoration(shape: BoxShape.circle, ...)) + ClipOval`. When we
/// wanted to flip rounded-rect to circle, that meant editing three
/// places. Consolidating here means the next visual tweak (border
/// width, shadow, outline highlight) lands in one file.
///
/// Two image-source modes:
///   * **bytes** — decoded PNG / JPEG (used by Apps tile + chip via
///     `pkg.icon`'s base64 PNG payload).
///   * **child** — caller supplies their own painter (used by the
///     mini-apps tile, which has its own `MiniAppRemoteImage` widget
///     that handles network fetch + caching).
///
/// Either both are null (then the [fallback] character renders) or
/// exactly one is provided.
class CircleAppIcon extends StatelessWidget {
  const CircleAppIcon({
    super.key,
    this.bytes,
    this.child,
    this.fallback = '?',
    this.diameter = 72,
    this.shadow = true,
    this.borderColor,
    this.borderWidth = 0,
    this.clusterBadge = false,
  });

  /// Decoded image bytes. Wins over [child] if both supplied.
  final Uint8List? bytes;

  /// Custom painter — used for cases where the caller has its own
  /// loading / placeholder strategy (e.g. mini-apps' remote image).
  final Widget? child;

  /// Single character drawn inside the circle when no image is
  /// available. Conventionally the first letter of the app's label.
  final String fallback;

  /// Outer diameter in logical pixels. The default 72 px matches
  /// the App-Store-style tile sizing the rest of the home pane uses.
  final double diameter;

  /// Whether to render the soft drop shadow under the circle. Off
  /// for chip-sized variants (the picker card already has its own
  /// frame; an inner shadow would muddy it).
  final bool shadow;

  /// Outline ring colour. Null = no ring.
  final Color? borderColor;

  /// Outline ring width in logical pixels. Ignored when
  /// [borderColor] is null.
  final double borderWidth;

  /// When true, overlays a small speedometer badge at the
  /// bottom-right — marks an app the host fresh-launches on the
  /// driver cluster (native `ClusterLaunchPolicy`: ReVanced/-patched
  /// builds, or user-added). Purely cosmetic; the decision is
  /// native. Off everywhere by default so non-foreign-app surfaces
  /// (mini-app tiles) never show it.
  final bool clusterBadge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shadowList = shadow
        ? <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ]
        : null;
    final circle = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        shape: BoxShape.circle,
        boxShadow: shadowList,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: borderWidth),
      ),
      child: ClipOval(
        child: bytes != null
            ? Image.memory(bytes!, fit: BoxFit.contain, gaplessPlayback: true)
            : child ??
                  Center(
                    child: Text(
                      fallback,
                      style: TextStyle(
                        fontSize: diameter * 0.4,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
      ),
    );
    if (!clusterBadge) return circle;
    // Overlay must not be clipped by the circle, so wrap in a Stack
    // sized to the icon with a slightly-overhanging badge.
    final badge = (diameter * 0.34).clamp(14.0, 26.0).toDouble();
    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                color: cs.tertiary,
                shape: BoxShape.circle,
                border: Border.all(color: cs.surface, width: 1.5),
              ),
              child: Icon(
                Icons.speed,
                size: badge * 0.62,
                color: cs.onTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
