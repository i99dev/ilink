import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/ui/theme/app_theme.dart';
import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/kernel/ui/theme/theme_spec.dart';

/// Inert-guarantee guard (THEMES_CONTRACT.md §7): after refactoring
/// `AppTheme` onto the data-driven `fromSpec` path, the built-in
/// `dark()` / `light()` must produce the SAME key ColorScheme + scaffold
/// values as the pre-refactor hard-coded palettes. These literals are
/// copied from the original `_darkPalette` / `_lightPalette` +
/// `AppColors` so the test fails loudly if the built-in spec ever drifts
/// from today's look.
void main() {
  group('AppTheme.dark() built-in parity', () {
    final theme = AppTheme.dark();
    final cs = theme.colorScheme;

    test('brightness is dark', () {
      expect(cs.brightness, Brightness.dark);
    });

    test('scaffold + surface tones match the historical _darkPalette', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFF07070D));
      expect(cs.surface, const Color(0xFF07070D));
      expect(cs.surfaceContainerLowest, const Color(0xFF07070D));
      expect(cs.surfaceContainerLow, const Color(0xFF0F1018));
      expect(cs.surfaceContainer, const Color(0xFF13141C));
      expect(cs.surfaceContainerHigh, const Color(0xFF1A1C26));
      expect(cs.surfaceContainerHighest, const Color(0xFF1A1C26));
      expect(cs.onSurface, const Color(0xFFF3F4F8));
      expect(cs.onSurfaceVariant, const Color(0xFF8A90A4));
      expect(cs.outline, const Color(0xFF4B5064));
      expect(cs.outlineVariant, const Color(0xFF24262F));
    });

    test('brand slots match AppColors', () {
      expect(cs.primary, AppColors.accent);
      expect(cs.secondary, AppColors.secondary);
      expect(cs.error, AppColors.error);
      expect(cs.onPrimary, Colors.black);
      expect(cs.onSecondary, Colors.white);
      expect(cs.onError, Colors.white);
    });

    test('divider + card surface unchanged', () {
      expect(theme.dividerColor, const Color(0xFF24262F));
      expect(theme.cardTheme.color, const Color(0xFF13141C));
    });
  });

  group('AppTheme.light() built-in parity', () {
    final theme = AppTheme.light();
    final cs = theme.colorScheme;

    test('brightness is light', () {
      expect(cs.brightness, Brightness.light);
    });

    test('scaffold + surface tones match the historical _lightPalette', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF7F7FA));
      expect(cs.surface, const Color(0xFFF7F7FA));
      expect(cs.surfaceContainerLowest, const Color(0xFFF7F7FA));
      expect(cs.surfaceContainerLow, const Color(0xFFF1F2F5));
      expect(cs.surfaceContainer, const Color(0xFFFFFFFF));
      expect(cs.surfaceContainerHigh, const Color(0xFFFAFAFC));
      expect(cs.surfaceContainerHighest, const Color(0xFFFAFAFC));
      expect(cs.onSurface, const Color(0xFF0B0C14));
      expect(cs.onSurfaceVariant, const Color(0xFF5B6170));
      expect(cs.outline, const Color(0xFF8E92A2));
      expect(cs.outlineVariant, const Color(0xFFE1E3E8));
    });

    test('brand slots match AppColors', () {
      expect(cs.primary, AppColors.accent);
      expect(cs.secondary, AppColors.secondary);
      expect(cs.error, AppColors.error);
    });
  });

  group('AppTheme.fromSpec wiring', () {
    test('routes ColorScheme.primary from spec.colors.accent', () {
      const spec = ThemeSpec(
        brightness: ThemeBrightness.dark,
        colors: ThemeColors(
          background: Color(0xFF000000),
          surfaceLow: Color(0xFF111111),
          surfaceContainer: Color(0xFF222222),
          surfaceHigh: Color(0xFF333333),
          outline: Color(0xFF444444),
          outlineVariant: Color(0xFF555555),
          onSurface: Color(0xFFFFFFFF),
          onSurfaceVariant: Color(0xFFCCCCCC),
          accent: Color(0xFFFF2E97),
          secondary: Color(0xFF22D3EE),
          error: Color(0xFFE76F51),
        ),
        shape: ThemeShape(cardRadius: 16, buttonRadius: 8, inputRadius: 8),
      );
      final theme = AppTheme.fromSpec(spec);
      expect(theme.colorScheme.primary, const Color(0xFFFF2E97));
      expect(theme.colorScheme.secondary, const Color(0xFF22D3EE));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      // Card radius flows from spec.shape.
      final cardShape = theme.cardTheme.shape;
      expect(cardShape, isA<RoundedRectangleBorder>());
      expect(
        (cardShape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(16),
      );
    });

    test('language code ar selects the Cairo family', () {
      final theme = AppTheme.fromSpec(kBuiltInDarkSpec, languageCode: 'ar');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Cairo');
    });
  });
}
