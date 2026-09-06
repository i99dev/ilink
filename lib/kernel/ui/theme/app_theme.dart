import 'package:flutter/material.dart';

import 'theme_spec.dart';

/// Builds the app's [ThemeData] from a data-driven [ThemeSpec]
/// (THEMES_CONTRACT.md §6). The built-in `dark()` / `light()` factories
/// are thin wrappers over the const built-in specs
/// ([kBuiltInDarkSpec] / [kBuiltInLightSpec]) that reproduce the
/// historical `_darkPalette` / `_lightPalette` + `AppColors` exactly —
/// so the app looks byte-identical when no theme is selected (the
/// feature ships inert, contract §7). A catalog theme flows the same
/// path via [AppTheme.fromSpec], routing `ColorScheme.primary` from
/// `spec.colors.accent` and the card / button / input radii from
/// `spec.shape`.
///
/// Widgets never read the spec's surface tones directly — they go
/// through `Theme.of(context).colorScheme.*`, exactly as before.
class AppTheme {
  const AppTheme._();

  static ThemeData dark({String languageCode = 'en'}) =>
      fromSpec(kBuiltInDarkSpec, languageCode: languageCode);

  static ThemeData light({String languageCode = 'en'}) =>
      fromSpec(kBuiltInLightSpec, languageCode: languageCode);

  /// Data-driven entry point. Maps the [ThemeSpec] design tokens onto a
  /// Material 3 [ThemeData]. The `colors.accent` token drives
  /// `ColorScheme.primary` (replacing the old direct `AppColors.accent`
  /// reference); the 8 surface tones map onto the ColorScheme surface
  /// slots; `shape.*` radii drive the card / button / input shapes.
  static ThemeData fromSpec(ThemeSpec spec, {String languageCode = 'en'}) {
    final brightness = spec.brightness == ThemeBrightness.dark
        ? Brightness.dark
        : Brightness.light;
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    final isArabic = languageCode == 'ar';
    // Cairo + Inter ship as bundled assets via pubspec.yaml's
    // `flutter.fonts:` block (see bundle worktree). We pick the family
    // string up via Flutter's native font registry — no google_fonts
    // network/fallback path. Cairo covers Latin too, so a single family
    // works for the whole app and avoids mid-string font swaps when
    // mixing numerals, English brand names, and Arabic labels.
    //
    // A theme may override the family via `typography.family`; v1
    // prefers system families, so an unset / bundled-only override
    // falls back to the locale default.
    final localeFamily = isArabic ? 'Cairo' : 'Inter';
    final family = spec.typography?.family ?? localeFamily;
    final textTheme = base.textTheme.apply(fontFamily: family);

    final c = spec.colors;
    final Color onSurface = c.onSurface;
    final Color onSurfaceVariant = c.onSurfaceVariant;
    // Glass: make the surface CONTAINERS translucent so the (optionally
    // animated) backdrop shows through, and tint the rim with the accent
    // for the glassy edge. Applied centrally on the ColorScheme so every
    // `colorScheme.surfaceContainer*` consumer — panels, tiles, icon
    // chips — inherits the look with no per-widget BackdropFilter (cheap
    // on the car GPU). The base `surface`/scaffold stays opaque and the
    // text tones stay fully opaque for legibility.
    final glass = spec.surfaceStyle == ThemeSurfaceStyle.glass;
    Color glassy(Color base, double alpha) =>
        glass ? base.withValues(alpha: alpha) : base;
    final Color outlineVariant = glass
        ? Color.alphaBlend(c.accent.withValues(alpha: 0.40), c.outlineVariant)
        : c.outlineVariant;
    final Color glassCard = glassy(c.surfaceContainer, 0.58);
    final titleStyle = TextStyle(
      fontFamily: family,
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: onSurface,
    );
    final colorScheme =
        (brightness == Brightness.dark ? ColorScheme.dark : ColorScheme.light)(
          primary: c.accent,
          secondary: c.secondary,
          error: c.error,
          onPrimary: Colors.black,
          onSecondary: Colors.white,
          onError: Colors.white,
          surface: c.background,
          surfaceContainerLowest: c.background,
          surfaceContainerLow: glassy(c.surfaceLow, 0.52),
          surfaceContainer: glassy(c.surfaceContainer, 0.58),
          surfaceContainerHigh: glassy(c.surfaceHigh, 0.62),
          surfaceContainerHighest: glassy(c.surfaceHigh, 0.68),
          onSurface: onSurface,
          onSurfaceVariant: onSurfaceVariant,
          outline: c.outline,
          outlineVariant: outlineVariant,
        );
    final shape = spec.shape;
    return base.copyWith(
      scaffoldBackgroundColor: c.background,
      colorScheme: colorScheme,
      cardTheme: CardThemeData(
        color: glassCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(shape.cardRadius)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: titleStyle,
        iconTheme: IconThemeData(color: onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glassy(c.surfaceHigh, 0.62),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(shape.inputRadius),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(shape.buttonRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: textTheme.copyWith(
        displayLarge: textTheme.displayLarge?.copyWith(
          fontWeight: FontWeight.w200,
          letterSpacing: -2,
          color: onSurface,
        ),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: onSurface,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          color: onSurfaceVariant,
          fontSize: 12,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(color: onSurface),
      ),
      dividerColor: outlineVariant,
    );
  }
}
