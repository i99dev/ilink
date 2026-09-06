import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/theme_spec.dart';
import '../../../mini_apps/presentation/widgets/mini_app_remote_image.dart';
import '../../state/theme_providers.dart';

/// Paints the active theme's backdrop behind the dashboard surface.
///
/// Priority order:
///   1. **No theme active** → `SizedBox.shrink()`. The default look stays
///      inert; the scaffold's flat background shows.
///   2. **Active theme with a `wallpaper` image** → that cover-fit image.
///   3. **Active theme without an image** → a procedural backdrop derived
///      from the theme's own colors. `spec.animatedBackground` upgrades it
///      to a slow drifting "aurora" of accent + secondary glows — a live
///      wallpaper without shipping any asset; otherwise a static
///      two-corner gradient. Either way each theme gets a visibly
///      distinct background while the readable middle stays the theme
///      background so foreground text/cards keep contrast.
///
/// Cheap by construction: a cached image, or a single `CustomPaint`
/// (animated path wrapped in a `RepaintBoundary`; no `BackdropFilter`).
class ThemeWallpaperLayer extends ConsumerWidget {
  const ThemeWallpaperLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = ref.watch(activeThemeSpecProvider);
    if (spec == null) return const SizedBox.shrink();

    final wallpaper = spec.wallpaper;
    final imageUrl = wallpaper == null
        ? null
        : (spec.brightness == ThemeBrightness.dark
              ? (wallpaper.homeDark ?? wallpaper.home)
              : wallpaper.home);
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return Positioned.fill(
        child: IgnorePointer(
          child: MiniAppRemoteImage(
            url: imageUrl,
            fit: BoxFit.cover,
            fallback: _ProceduralBackdrop(spec: spec),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: IgnorePointer(child: _ProceduralBackdrop(spec: spec)),
    );
  }
}

/// Picks the animated or static backdrop from `spec.animatedBackground`.
class _ProceduralBackdrop extends StatelessWidget {
  const _ProceduralBackdrop({required this.spec});

  final ThemeSpec spec;

  @override
  Widget build(BuildContext context) {
    if (spec.animatedBackground) {
      return _AnimatedBackdrop(colors: spec.colors);
    }
    return _StaticBackdrop(colors: spec.colors);
  }
}

/// Static two-corner gradient: `accent` tints the top-leading corner and
/// `secondary` the bottom-trailing corner over the theme background.
/// Opaque (middle stops are the background) so it cleanly replaces the
/// flat scaffold fill.
class _StaticBackdrop extends StatelessWidget {
  const _StaticBackdrop({required this.colors});

  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final bg = colors.background;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          stops: const [0.0, 0.36, 0.64, 1.0],
          colors: [
            Color.alphaBlend(colors.accent.withValues(alpha: 0.22), bg),
            bg,
            bg,
            Color.alphaBlend(colors.secondary.withValues(alpha: 0.18), bg),
          ],
        ),
      ),
    );
  }
}

/// A slow drifting aurora: two radial glows (accent + secondary) orbit on
/// out-of-phase ellipses over the theme background. ~18s loop, painted in
/// a single `CustomPaint` inside a `RepaintBoundary` so it never dirties
/// the dashboard above it.
class _AnimatedBackdrop extends StatefulWidget {
  const _AnimatedBackdrop({required this.colors});

  final ThemeColors colors;

  @override
  State<_AnimatedBackdrop> createState() => _AnimatedBackdropState();
}

class _AnimatedBackdropState extends State<_AnimatedBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size.infinite,
          painter: _AuroraPainter(colors: widget.colors, t: _c.value),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.colors, required this.t});

  final ThemeColors colors;

  /// Animation phase 0..1.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = colors.background);
    final tau = t * 2 * math.pi;
    _glow(
      canvas,
      size,
      colors.accent,
      Offset(0.24 + 0.14 * math.cos(tau), 0.20 + 0.10 * math.sin(tau)),
      0.95,
      0.30,
    );
    _glow(
      canvas,
      size,
      colors.secondary,
      Offset(
        0.78 + 0.14 * math.cos(tau + math.pi),
        0.82 + 0.10 * math.sin(tau + math.pi),
      ),
      1.05,
      0.24,
    );
  }

  void _glow(
    Canvas canvas,
    Size size,
    Color color,
    Offset frac,
    double radiusFrac,
    double alpha,
  ) {
    final center = Offset(frac.dx * size.width, frac.dy * size.height);
    final radius = radiusFrac * size.longestSide;
    final shader = RadialGradient(
      colors: [
        color.withValues(alpha: alpha),
        color.withValues(alpha: 0),
      ],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t || old.colors != colors;
}
