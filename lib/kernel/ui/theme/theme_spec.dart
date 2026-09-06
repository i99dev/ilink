import 'dart:ui' show Color;

import 'colors.dart';

/// Schema version of the [ThemeSpec] document. Mirrors the contract's
/// `THEME_SCHEMA = 1` (THEMES_CONTRACT.md §2) and the SDK / backend
/// constants. A spec declaring a higher schema carries design tokens
/// this build can't interpret — the catalog `requires.schema` gate
/// (reused from mini-apps) fail-closes those rows; the parser itself
/// stays lenient so a malformed row degrades to the built-in default
/// rather than crashing the catalog.
const int kThemeSchema = 1;

/// Default shape radii (THEMES_CONTRACT.md §2 `shape`). These reproduce
/// today's hard-coded `app_theme.dart` radii exactly, so a spec that
/// omits `shape` (or the whole built-in spec) renders byte-identical to
/// the pre-theming look.
const double kDefaultCardRadius = 24;
const double kDefaultButtonRadius = 14;
const double kDefaultInputRadius = 14;

/// Parses a hex color string per the contract regex
/// `^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$` — `#RRGGBB` (opaque) or
/// `#AARRGGBB` (with alpha). Returns null on anything malformed so the
/// caller can fall back to a default rather than paint a wrong color.
///
/// Defensive by design (mirrors the `mini_app.dart` parse discipline):
/// a single bad token in a remote catalog row must never throw.
Color? parseHexColor(String? raw) {
  if (raw == null) return null;
  var hex = raw.trim();
  if (hex.isEmpty || hex[0] != '#') return null;
  hex = hex.substring(1);
  if (hex.length == 6) {
    // Opaque RRGGBB → prepend full alpha.
    hex = 'FF$hex';
  } else if (hex.length != 8) {
    return null;
  }
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(value);
}

/// Serialises a [Color] back to the contract's `#AARRGGBB` form. Always
/// emits 8 digits (alpha-first) so a round-trip through [parseHexColor]
/// is lossless even for translucent surfaces.
String colorToHex(Color color) {
  final argb = color.toARGB32() & 0xFFFFFFFF;
  return '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

/// `"light" | "dark"` — drives the [ThemeData] base brightness. Parsed
/// leniently: an unknown / missing value defaults to dark (the app's
/// historical default palette).
enum ThemeBrightness {
  light,
  dark;

  static ThemeBrightness fromWire(String? raw) {
    if (raw == 'light') return ThemeBrightness.light;
    return ThemeBrightness.dark;
  }

  String get wire => name;
}

/// Surface rendering style (THEMES_CONTRACT.md §2 `surfaceStyle`).
///   * `solid` — opaque panels/cards/tiles (the historical look).
///   * `glass` — translucent surface containers so the (optionally
///     animated) backdrop shows through, with accent-tinted edges. A
///     glassmorphism look applied centrally via the ColorScheme in
///     `AppTheme.fromSpec`, so every surface that reads
///     `colorScheme.surfaceContainer*` (panels, tiles, icon chips)
///     inherits it — no per-widget blur, cheap on the car GPU.
/// Lenient parse: unknown / missing → `solid`.
enum ThemeSurfaceStyle {
  solid,
  glass;

  static ThemeSurfaceStyle fromWire(String? raw) {
    if (raw == 'glass') return ThemeSurfaceStyle.glass;
    return ThemeSurfaceStyle.solid;
  }

  String get wire => name;
}

/// The 8 surface tones + the brand/semantic accents of a [ThemeSpec].
/// The surface keys map 1:1 onto the car's private `_Palette`
/// (`app_theme.dart`); the brand keys map onto Material `ColorScheme`
/// slots / `AppColors`. All 8 surfaces + accent/secondary/error are
/// REQUIRED on the wire; warning/neutral are optional and default to
/// the [AppColors] brand constants.
class ThemeColors {
  const ThemeColors({
    required this.background,
    required this.surfaceLow,
    required this.surfaceContainer,
    required this.surfaceHigh,
    required this.outline,
    required this.outlineVariant,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.accent,
    required this.secondary,
    required this.error,
    this.warning = AppColors.warning,
    this.neutral = AppColors.neutral,
  });

  // --- surfaces (→ _Palette) ---
  final Color background;
  final Color surfaceLow;
  final Color surfaceContainer;
  final Color surfaceHigh;
  final Color outline;
  final Color outlineVariant;
  final Color onSurface;
  final Color onSurfaceVariant;

  // --- brand / semantic (→ ColorScheme / AppColors) ---
  final Color accent;
  final Color secondary;
  final Color error;
  final Color warning;
  final Color neutral;

  /// Defensive parse. Every required surface / accent falls back to the
  /// built-in dark spec's value when absent or malformed so one bad
  /// field can't blank out the whole theme. `fallback` lets the
  /// brightness-appropriate built-in supply the per-key default (so a
  /// partially-specified light theme borrows light surfaces, not dark).
  factory ThemeColors.fromJson(
    Map<String, Object?> json, {
    required ThemeColors fallback,
  }) {
    Color pick(String key, Color dflt) =>
        parseHexColor(json[key] as String?) ?? dflt;
    return ThemeColors(
      background: pick('background', fallback.background),
      surfaceLow: pick('surfaceLow', fallback.surfaceLow),
      surfaceContainer: pick('surfaceContainer', fallback.surfaceContainer),
      surfaceHigh: pick('surfaceHigh', fallback.surfaceHigh),
      outline: pick('outline', fallback.outline),
      outlineVariant: pick('outlineVariant', fallback.outlineVariant),
      onSurface: pick('onSurface', fallback.onSurface),
      onSurfaceVariant: pick('onSurfaceVariant', fallback.onSurfaceVariant),
      accent: pick('accent', fallback.accent),
      secondary: pick('secondary', fallback.secondary),
      error: pick('error', fallback.error),
      warning: pick('warning', fallback.warning),
      neutral: pick('neutral', fallback.neutral),
    );
  }

  Map<String, Object?> toJson() => {
    'background': colorToHex(background),
    'surfaceLow': colorToHex(surfaceLow),
    'surfaceContainer': colorToHex(surfaceContainer),
    'surfaceHigh': colorToHex(surfaceHigh),
    'outline': colorToHex(outline),
    'outlineVariant': colorToHex(outlineVariant),
    'onSurface': colorToHex(onSurface),
    'onSurfaceVariant': colorToHex(onSurfaceVariant),
    'accent': colorToHex(accent),
    'secondary': colorToHex(secondary),
    'error': colorToHex(error),
    'warning': colorToHex(warning),
    'neutral': colorToHex(neutral),
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeColors &&
      other.background == background &&
      other.surfaceLow == surfaceLow &&
      other.surfaceContainer == surfaceContainer &&
      other.surfaceHigh == surfaceHigh &&
      other.outline == outline &&
      other.outlineVariant == outlineVariant &&
      other.onSurface == onSurface &&
      other.onSurfaceVariant == onSurfaceVariant &&
      other.accent == accent &&
      other.secondary == secondary &&
      other.error == error &&
      other.warning == warning &&
      other.neutral == neutral;

  @override
  int get hashCode => Object.hash(
    background,
    surfaceLow,
    surfaceContainer,
    surfaceHigh,
    outline,
    outlineVariant,
    onSurface,
    onSurfaceVariant,
    accent,
    secondary,
    error,
    warning,
    neutral,
  );
}

/// Optional wallpaper layer (THEMES_CONTRACT.md §2 `wallpaper`). Each
/// field is an absolute HTTPS CDN URL once the publish service rewrites
/// the `./...` asset path; null when the publisher didn't ship one.
/// Painted behind the home / cluster surfaces; no-op when unset.
class ThemeWallpaper {
  const ThemeWallpaper({this.home, this.homeDark, this.cluster});

  final String? home;
  final String? homeDark;
  final String? cluster;

  bool get isEmpty => home == null && homeDark == null && cluster == null;

  static ThemeWallpaper? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    String? str(Object? v) => (v is String && v.trim().isNotEmpty) ? v : null;
    final w = ThemeWallpaper(
      home: str(m['home']),
      homeDark: str(m['homeDark']),
      cluster: str(m['cluster']),
    );
    return w.isEmpty ? null : w;
  }

  Map<String, Object?> toJson() => {
    if (home != null) 'home': home,
    if (homeDark != null) 'homeDark': homeDark,
    if (cluster != null) 'cluster': cluster,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeWallpaper &&
      other.home == home &&
      other.homeDark == homeDark &&
      other.cluster == cluster;

  @override
  int get hashCode => Object.hash(home, homeDark, cluster);
}

/// Optional typography override (THEMES_CONTRACT.md §2 `typography`).
/// `family` is a system / bundled font name; in v1 we prefer system
/// families (Inter / Cairo by locale) and ignore `bundled` fonts (T2).
class ThemeTypography {
  const ThemeTypography({this.family, this.bundled = false});

  /// Font family name. Null → keep the host's locale-default family
  /// (Inter for Latin, Cairo for Arabic).
  final String? family;

  /// `true` ⇒ the family ships in the bundle's `fonts/`. v1 ignores
  /// this (system families only); kept for forward-compat parse.
  final bool bundled;

  static ThemeTypography? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    final family = m['family'];
    final t = ThemeTypography(
      family: (family is String && family.trim().isNotEmpty) ? family : null,
      bundled: m['bundled'] is bool ? m['bundled'] as bool : false,
    );
    if (t.family == null && !t.bundled) return null;
    return t;
  }

  Map<String, Object?> toJson() => {
    if (family != null) 'family': family,
    'bundled': bundled,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeTypography &&
      other.family == family &&
      other.bundled == bundled;

  @override
  int get hashCode => Object.hash(family, bundled);
}

/// Optional shape radii (THEMES_CONTRACT.md §2 `shape`). Each radius is
/// clamped to 0..48 on parse. Defaults preserve today's look exactly.
class ThemeShape {
  const ThemeShape({
    this.cardRadius = kDefaultCardRadius,
    this.buttonRadius = kDefaultButtonRadius,
    this.inputRadius = kDefaultInputRadius,
  });

  final double cardRadius;
  final double buttonRadius;
  final double inputRadius;

  static const ThemeShape defaults = ThemeShape();

  static ThemeShape fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    final m = raw.cast<Object?, Object?>();
    double clampRadius(Object? v, double dflt) {
      if (v is! num) return dflt;
      return v.toDouble().clamp(0, 48).toDouble();
    }

    return ThemeShape(
      cardRadius: clampRadius(m['cardRadius'], kDefaultCardRadius),
      buttonRadius: clampRadius(m['buttonRadius'], kDefaultButtonRadius),
      inputRadius: clampRadius(m['inputRadius'], kDefaultInputRadius),
    );
  }

  Map<String, Object?> toJson() => {
    'cardRadius': cardRadius,
    'buttonRadius': buttonRadius,
    'inputRadius': inputRadius,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeShape &&
      other.cardRadius == cardRadius &&
      other.buttonRadius == buttonRadius &&
      other.inputRadius == inputRadius;

  @override
  int get hashCode => Object.hash(cardRadius, buttonRadius, inputRadius);
}

/// Optional gauge skin (THEMES_CONTRACT.md §2 `gauge`, T3). The car may
/// ignore this in v1 — parsed + round-tripped for forward-compat only.
class ThemeGauge {
  const ThemeGauge({this.skin, this.ringColor});

  final String? skin;
  final Color? ringColor;

  static ThemeGauge? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    final skin = m['skin'];
    final g = ThemeGauge(
      skin: (skin is String && skin.trim().isNotEmpty) ? skin : null,
      ringColor: parseHexColor(m['ringColor'] as String?),
    );
    if (g.skin == null && g.ringColor == null) return null;
    return g;
  }

  Map<String, Object?> toJson() => {
    if (skin != null) 'skin': skin,
    if (ringColor != null) 'ringColor': colorToHex(ringColor!),
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeGauge && other.skin == skin && other.ringColor == ringColor;

  @override
  int get hashCode => Object.hash(skin, ringColor);
}

/// The design-token document a car consumes to build a [ThemeData]
/// (THEMES_CONTRACT.md §2). Wire-identical (camelCase) to the SDK /
/// backend / website reference implementations. Immutable; parsed
/// defensively so a malformed remote row degrades to the built-in
/// default rather than crashing the catalog.
class ThemeSpec {
  const ThemeSpec({
    this.schema = kThemeSchema,
    required this.brightness,
    required this.colors,
    this.wallpaper,
    this.typography,
    this.shape = ThemeShape.defaults,
    this.gauge,
    this.surfaceStyle = ThemeSurfaceStyle.solid,
    this.animatedBackground = false,
  });

  /// Schema version. Defaults to [kThemeSchema] when omitted.
  final int schema;

  final ThemeBrightness brightness;
  final ThemeColors colors;
  final ThemeWallpaper? wallpaper;
  final ThemeTypography? typography;
  final ThemeShape shape;
  final ThemeGauge? gauge;

  /// Solid (default, historical look) or glass (translucent surfaces).
  final ThemeSurfaceStyle surfaceStyle;

  /// When `true`, the procedural backdrop drifts/animates (a subtle
  /// "live wallpaper"). Default `false` so the inert built-in default
  /// and any plain theme stay static. Ignored when an image wallpaper is
  /// present (the image wins).
  final bool animatedBackground;

  /// Lenient parse. The brightness is read first so per-key color
  /// fallbacks borrow the *matching* built-in (light theme → light
  /// surfaces). Unknown / malformed → built-in default for that key.
  factory ThemeSpec.fromJson(Map<String, Object?> json) {
    final brightness = ThemeBrightness.fromWire(json['brightness'] as String?);
    final fallback = brightness == ThemeBrightness.light
        ? kBuiltInLightSpec.colors
        : kBuiltInDarkSpec.colors;
    final schemaRaw = json['schema'];
    final colorsRaw = json['colors'];
    return ThemeSpec(
      schema: schemaRaw is num ? schemaRaw.toInt() : kThemeSchema,
      brightness: brightness,
      colors: colorsRaw is Map
          ? ThemeColors.fromJson(
              colorsRaw.cast<String, Object?>(),
              fallback: fallback,
            )
          : fallback,
      wallpaper: ThemeWallpaper.fromJson(json['wallpaper']),
      typography: ThemeTypography.fromJson(json['typography']),
      shape: ThemeShape.fromJson(json['shape']),
      gauge: ThemeGauge.fromJson(json['gauge']),
      surfaceStyle: ThemeSurfaceStyle.fromWire(json['surfaceStyle'] as String?),
      animatedBackground: json['animatedBackground'] is bool
          ? json['animatedBackground'] as bool
          : false,
    );
  }

  Map<String, Object?> toJson() => {
    'schema': schema,
    'brightness': brightness.wire,
    'colors': colors.toJson(),
    if (wallpaper != null) 'wallpaper': wallpaper!.toJson(),
    if (typography != null) 'typography': typography!.toJson(),
    'shape': shape.toJson(),
    if (gauge != null) 'gauge': gauge!.toJson(),
    'surfaceStyle': surfaceStyle.wire,
    'animatedBackground': animatedBackground,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeSpec &&
      other.schema == schema &&
      other.brightness == brightness &&
      other.colors == colors &&
      other.wallpaper == wallpaper &&
      other.typography == typography &&
      other.shape == shape &&
      other.gauge == gauge &&
      other.surfaceStyle == surfaceStyle &&
      other.animatedBackground == animatedBackground;

  @override
  int get hashCode => Object.hash(
    schema,
    brightness,
    colors,
    wallpaper,
    typography,
    shape,
    gauge,
    surfaceStyle,
    animatedBackground,
  );
}

/// Built-in **dark** spec — reproduces `_darkPalette` + [AppColors]
/// EXACTLY (THEMES_CONTRACT.md §6). `AppTheme.dark()` is a thin wrapper
/// over `AppTheme.fromSpec(kBuiltInDarkSpec)`, so the app's default
/// look is unchanged when no theme is selected (the feature ships
/// inert, contract §7).
const ThemeSpec kBuiltInDarkSpec = ThemeSpec(
  brightness: ThemeBrightness.dark,
  colors: ThemeColors(
    background: Color(0xFF07070D),
    surfaceLow: Color(0xFF0F1018),
    surfaceContainer: Color(0xFF13141C),
    surfaceHigh: Color(0xFF1A1C26),
    outline: Color(0xFF4B5064),
    outlineVariant: Color(0xFF24262F),
    onSurface: Color(0xFFF3F4F8),
    onSurfaceVariant: Color(0xFF8A90A4),
    accent: AppColors.accent,
    secondary: AppColors.secondary,
    error: AppColors.error,
    warning: AppColors.warning,
    neutral: AppColors.neutral,
  ),
);

/// Built-in **light** spec — reproduces `_lightPalette` + [AppColors]
/// EXACTLY. `AppTheme.light()` wraps `AppTheme.fromSpec(kBuiltInLightSpec)`.
const ThemeSpec kBuiltInLightSpec = ThemeSpec(
  brightness: ThemeBrightness.light,
  colors: ThemeColors(
    background: Color(0xFFF7F7FA),
    surfaceLow: Color(0xFFF1F2F5),
    surfaceContainer: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFFAFAFC),
    outline: Color(0xFF8E92A2),
    outlineVariant: Color(0xFFE1E3E8),
    onSurface: Color(0xFF0B0C14),
    onSurfaceVariant: Color(0xFF5B6170),
    accent: AppColors.accent,
    secondary: AppColors.secondary,
    error: AppColors.error,
    warning: AppColors.warning,
    neutral: AppColors.neutral,
  ),
);
