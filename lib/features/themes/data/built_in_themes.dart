import 'dart:ui' show Color;

import '../../../kernel/ui/theme/colors.dart';
import '../../../kernel/ui/theme/theme_spec.dart';
import '../domain/theme_item.dart';

/// Stable id of the built-in **dark** theme. This is also the implicit
/// active theme when `AppSettings.activeThemeId` is empty — i.e. the
/// app's historical default look. Kept as a const so the resolver and
/// the UI agree on "what does empty mean".
const String kMidnightThemeId = 'midnight';

/// Stable id of the built-in **light** theme (current light palette).
const String kDaylightThemeId = 'daylight';

/// Stable id of the new built-in **neon** showcase theme.
const String kNeonThemeId = 'neon';

/// Stable id of the built-in **aurora** glass showcase theme.
const String kAuroraThemeId = 'aurora';

/// The three themes that ship inside the APK. Listed first in the
/// gallery so a fresh / offline car always has a working picker (no
/// network round-trip needed). [kMidnightThemeId] / [kDaylightThemeId]
/// re-use the const built-in specs verbatim, so applying them is a
/// no-op against today's look. "Neon" is a new high-contrast dark skin
/// that exercises the data-driven path end-to-end.
const List<ThemeItem> kBuiltInThemes = <ThemeItem>[
  ThemeItem(
    id: kMidnightThemeId,
    name: {'en': 'Midnight', 'ar': 'منتصف الليل', 'ru': 'Полночь'},
    description: {
      'en': 'The classic dark dashboard — tuned for night driving.',
      'ar': 'لوحة القيادة الداكنة الكلاسيكية — مهيأة للقيادة الليلية.',
      'ru': 'Классическая тёмная панель — настроена для ночной езды.',
    },
    icon: '',
    version: '1.0.0',
    category: 'dark',
    isBuiltIn: true,
    spec: kBuiltInDarkSpec,
  ),
  ThemeItem(
    id: kDaylightThemeId,
    name: {'en': 'Daylight', 'ar': 'ضوء النهار', 'ru': 'Дневной свет'},
    description: {
      'en': 'A bright, warm light palette for daytime cabins.',
      'ar': 'لوحة فاتحة دافئة لقمرة القيادة نهارًا.',
      'ru': 'Светлая тёплая палитра для дневной поездки.',
    },
    icon: '',
    version: '1.0.0',
    category: 'light',
    isBuiltIn: true,
    spec: kBuiltInLightSpec,
  ),
  ThemeItem(
    id: kNeonThemeId,
    name: {'en': 'Neon', 'ar': 'نيون', 'ru': 'Неон'},
    description: {
      'en': 'High-contrast cyber dark with an electric magenta accent.',
      'ar': 'داكن سايبر عالي التباين بلمسة أرجوانية كهربائية.',
      'ru': 'Контрастный кибер-тёмный с электрик-маджентой.',
    },
    icon: '',
    version: '1.0.0',
    category: 'neon',
    isBuiltIn: true,
    spec: _neonSpec,
  ),
  ThemeItem(
    id: kAuroraThemeId,
    name: {'en': 'Aurora', 'ar': 'الشفق', 'ru': 'Аврора'},
    description: {
      'en': 'Frosted glass over a drifting teal-and-blue aurora.',
      'ar': 'زجاج مصنفر فوق شفق متحرك أزرق وفيروزي.',
      'ru': 'Матовое стекло над плывущим сине-бирюзовым сиянием.',
    },
    icon: '',
    version: '1.0.0',
    category: 'vibrant',
    isBuiltIn: true,
    spec: _auroraSpec,
  ),
];

/// Showcase spec — a deep near-black with an electric magenta accent,
/// **frosted-glass surfaces** and a **drifting animated backdrop**.
/// Exercises the full data-driven path (colors + shape + surfaceStyle +
/// animatedBackground) and is unmistakably different from Midnight.
const ThemeSpec _neonSpec = ThemeSpec(
  brightness: ThemeBrightness.dark,
  surfaceStyle: ThemeSurfaceStyle.glass,
  animatedBackground: true,
  colors: ThemeColors(
    background: Color(0xFF050507),
    surfaceLow: Color(0xFF0B0B12),
    surfaceContainer: Color(0xFF111119),
    surfaceHigh: Color(0xFF181826),
    outline: Color(0xFF6B5C8A),
    outlineVariant: Color(0xFF2A2438),
    onSurface: Color(0xFFF6F2FF),
    onSurfaceVariant: Color(0xFF9B8FB8),
    accent: Color(0xFFFF2E97),
    secondary: Color(0xFF22D3EE),
    error: AppColors.error,
    warning: AppColors.warning,
    neutral: AppColors.neutral,
  ),
  shape: ThemeShape(cardRadius: 16, buttonRadius: 10, inputRadius: 10),
);

/// Showcase spec — a deep teal-navy "northern lights" skin with a green
/// accent + blue secondary, frosted-glass surfaces and a drifting
/// animated backdrop. A second glass theme so the gallery shows the
/// capability across more than one palette.
const ThemeSpec _auroraSpec = ThemeSpec(
  brightness: ThemeBrightness.dark,
  surfaceStyle: ThemeSurfaceStyle.glass,
  animatedBackground: true,
  colors: ThemeColors(
    background: Color(0xFF06121A),
    surfaceLow: Color(0xFF0A1A24),
    surfaceContainer: Color(0xFF0E2330),
    surfaceHigh: Color(0xFF143040),
    outline: Color(0xFF3E6B7A),
    outlineVariant: Color(0xFF1C3A47),
    onSurface: Color(0xFFEAFBF6),
    onSurfaceVariant: Color(0xFF8FB8B0),
    accent: Color(0xFF3DDC97),
    secondary: Color(0xFF6AA0FF),
    error: AppColors.error,
    warning: AppColors.warning,
    neutral: AppColors.neutral,
  ),
  shape: ThemeShape(cardRadius: 20, buttonRadius: 14, inputRadius: 14),
);
