import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/themes/data/built_in_themes.dart';
import 'package:ilink/kernel/ui/theme/app_theme.dart';
import 'package:ilink/kernel/ui/theme/theme_spec.dart';

void main() {
  group('ThemeSpec surfaceStyle + animatedBackground', () {
    test('glass + animated round-trip through JSON', () {
      final neon = kBuiltInThemes.firstWhere((t) => t.id == kNeonThemeId).spec;
      expect(neon.surfaceStyle, ThemeSurfaceStyle.glass);
      expect(neon.animatedBackground, isTrue);

      final back = ThemeSpec.fromJson(neon.toJson());
      expect(back.surfaceStyle, ThemeSurfaceStyle.glass);
      expect(back.animatedBackground, isTrue);
      expect(back, neon);
    });

    test('unknown / missing surfaceStyle defaults to solid + static', () {
      final spec = ThemeSpec.fromJson({
        'brightness': 'dark',
        'colors': kBuiltInDarkSpec.colors.toJson(),
        'surfaceStyle': 'frosted-bogus',
      });
      expect(spec.surfaceStyle, ThemeSurfaceStyle.solid);
      expect(spec.animatedBackground, isFalse);
    });

    test('built-in default specs stay solid + static (inert guarantee)', () {
      expect(kBuiltInDarkSpec.surfaceStyle, ThemeSurfaceStyle.solid);
      expect(kBuiltInDarkSpec.animatedBackground, isFalse);
      expect(kBuiltInLightSpec.surfaceStyle, ThemeSurfaceStyle.solid);
      expect(kBuiltInLightSpec.animatedBackground, isFalse);
    });

    test('Aurora is a second glass + animated built-in', () {
      final aurora = kBuiltInThemes.firstWhere((t) => t.id == kAuroraThemeId);
      expect(aurora.spec.surfaceStyle, ThemeSurfaceStyle.glass);
      expect(aurora.spec.animatedBackground, isTrue);
    });
  });

  group('AppTheme.fromSpec glass surfaces', () {
    test('glass spec → translucent surface containers, opaque base', () {
      final neon = kBuiltInThemes.firstWhere((t) => t.id == kNeonThemeId).spec;
      final cs = AppTheme.fromSpec(neon).colorScheme;
      expect(cs.surfaceContainer.a, lessThan(1.0));
      expect(cs.surfaceContainerHigh.a, lessThan(1.0));
      // The base surface (scaffold fill) stays opaque so off-dashboard
      // screens never go see-through, and text tones stay solid.
      expect(cs.surface.a, 1.0);
      expect(cs.onSurface.a, 1.0);
    });

    test('solid (built-in) spec → fully opaque surface containers', () {
      final cs = AppTheme.dark().colorScheme;
      expect(cs.surfaceContainer.a, 1.0);
      expect(cs.surfaceContainerHigh.a, 1.0);
    });
  });
}
