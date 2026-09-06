import 'package:flutter/material.dart';

import '../../../../kernel/ui/theme/theme_spec.dart';

/// A compact palette preview for a [ThemeSpec]: the theme's background
/// with three accent / surface dots layered on it. Used as the tile
/// "cover" for built-in themes (which ship no cover image) and as a
/// fallback when a catalog theme's cover hasn't loaded. Renders the
/// theme's OWN colors (not the active app theme's), so the user sees
/// what they'd get before applying.
class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch({super.key, required this.spec, this.size = 56});

  final ThemeSpec spec;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = spec.colors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(spec.shape.cardRadius / 2),
        border: Border.all(color: c.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.all(size * 0.16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dot(c.accent, size * 0.26),
            Row(
              children: [
                _dot(c.secondary, size * 0.18),
                SizedBox(width: size * 0.08),
                _dot(c.onSurfaceVariant, size * 0.18),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color, double d) => Container(
    width: d,
    height: d,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
