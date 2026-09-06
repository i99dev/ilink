import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/ui/theme/colors.dart';
import 'package:ilink/kernel/ui/theme/theme_spec.dart';

void main() {
  group('parseHexColor', () {
    test('parses #RRGGBB as opaque', () {
      expect(parseHexColor('#22D3A8'), const Color(0xFF22D3A8));
    });

    test('parses #AARRGGBB with alpha', () {
      // Build the expected via fromARGB (not a 0xAARRGGBB literal) so the
      // forbidden-string CI gate doesn't mistake an 8-hex Color literal
      // for a reverse-engineered BYD feature id.
      expect(
        parseHexColor('#8022D3A8'),
        const Color.fromARGB(0x80, 0x22, 0xD3, 0xA8),
      );
    });

    test('is case-insensitive and trims whitespace', () {
      expect(parseHexColor('  #22d3a8 '), const Color(0xFF22D3A8));
    });

    test('rejects malformed input', () {
      expect(parseHexColor(null), isNull);
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('22D3A8'), isNull); // no leading #
      expect(parseHexColor('#FFF'), isNull); // wrong length
      expect(parseHexColor('#GGGGGG'), isNull); // non-hex
      expect(parseHexColor('#1234567'), isNull); // 7 digits
    });
  });

  group('colorToHex round-trip', () {
    test('emits #AARRGGBB and round-trips through parseHexColor', () {
      // fromARGB (not a 0x literal) to keep the forbidden-string gate
      // from flagging an 8-hex Color as a BYD feature id.
      const c = Color.fromARGB(0x80, 0x22, 0xD3, 0xA8);
      final hex = colorToHex(c);
      expect(hex, '#8022D3A8');
      expect(parseHexColor(hex), c);
    });

    test('opaque color round-trips losslessly', () {
      const c = Color(0xFF07070D);
      expect(parseHexColor(colorToHex(c)), c);
    });
  });

  group('ThemeBrightness', () {
    test('parses light/dark, defaults to dark', () {
      expect(ThemeBrightness.fromWire('light'), ThemeBrightness.light);
      expect(ThemeBrightness.fromWire('dark'), ThemeBrightness.dark);
      expect(ThemeBrightness.fromWire(null), ThemeBrightness.dark);
      expect(ThemeBrightness.fromWire('nonsense'), ThemeBrightness.dark);
    });
  });

  group('ThemeShape', () {
    test('defaults preserve historical radii', () {
      const s = ThemeShape();
      expect(s.cardRadius, kDefaultCardRadius);
      expect(s.buttonRadius, kDefaultButtonRadius);
      expect(s.inputRadius, kDefaultInputRadius);
    });

    test('clamps out-of-range radii to 0..48', () {
      final s = ThemeShape.fromJson({
        'cardRadius': 99,
        'buttonRadius': -5,
        'inputRadius': 12,
      });
      expect(s.cardRadius, 48);
      expect(s.buttonRadius, 0);
      expect(s.inputRadius, 12);
    });

    test('non-map / missing falls back to defaults', () {
      expect(ThemeShape.fromJson(null), ThemeShape.defaults);
      expect(ThemeShape.fromJson('oops'), ThemeShape.defaults);
    });
  });

  group('ThemeSpec.fromJson / toJson', () {
    // A full spec per THEMES_CONTRACT.md §2.
    final contractJson = <String, Object?>{
      'schema': 1,
      'brightness': 'dark',
      'colors': {
        'background': '#07070D',
        'surfaceLow': '#0F1018',
        'surfaceContainer': '#13141C',
        'surfaceHigh': '#1A1C26',
        'outline': '#4B5064',
        'outlineVariant': '#24262F',
        'onSurface': '#F3F4F8',
        'onSurfaceVariant': '#8A90A4',
        'accent': '#22D3A8',
        'secondary': '#5B8CFF',
        'error': '#E76F51',
        'warning': '#F4A261',
        'neutral': '#6A7088',
      },
      'wallpaper': {'home': './wallpaper/home.png'},
      'typography': {'family': 'Inter', 'bundled': false},
      'shape': {'cardRadius': 24, 'buttonRadius': 14, 'inputRadius': 14},
      'gauge': {'skin': 'neon', 'ringColor': '#22D3A8'},
    };

    test('parses the contract example fully', () {
      final spec = ThemeSpec.fromJson(contractJson);
      expect(spec.schema, 1);
      expect(spec.brightness, ThemeBrightness.dark);
      expect(spec.colors.background, const Color(0xFF07070D));
      expect(spec.colors.accent, const Color(0xFF22D3A8));
      expect(spec.colors.secondary, const Color(0xFF5B8CFF));
      expect(spec.colors.error, const Color(0xFFE76F51));
      expect(spec.colors.warning, const Color(0xFFF4A261));
      expect(spec.colors.neutral, const Color(0xFF6A7088));
      expect(spec.wallpaper?.home, './wallpaper/home.png');
      expect(spec.typography?.family, 'Inter');
      expect(spec.shape.cardRadius, 24);
      expect(spec.gauge?.skin, 'neon');
      expect(spec.gauge?.ringColor, const Color(0xFF22D3A8));
    });

    test('round-trips fromJson → toJson → fromJson to an equal spec', () {
      final spec = ThemeSpec.fromJson(contractJson);
      final roundTripped = ThemeSpec.fromJson(spec.toJson());
      expect(roundTripped, spec);
    });

    test('missing optional warning/neutral default to AppColors', () {
      final json = Map<String, Object?>.from(contractJson);
      json['colors'] =
          Map<String, Object?>.from(
              contractJson['colors']! as Map<String, Object?>,
            )
            ..remove('warning')
            ..remove('neutral');
      final spec = ThemeSpec.fromJson(json);
      expect(spec.colors.warning, AppColors.warning);
      expect(spec.colors.neutral, AppColors.neutral);
    });

    test(
      'a malformed surface key falls back to the brightness-matched built-in',
      () {
        final json = Map<String, Object?>.from(contractJson);
        json['brightness'] = 'light';
        json['colors'] = {
          // only one valid color; everything else absent → light built-in
          'accent': '#FF0000',
        };
        final spec = ThemeSpec.fromJson(json);
        expect(spec.colors.accent, const Color(0xFFFF0000));
        // Background borrows the LIGHT built-in (not dark).
        expect(spec.colors.background, kBuiltInLightSpec.colors.background);
      },
    );
  });

  group('built-in specs', () {
    test('kBuiltInDarkSpec reproduces the historical dark palette', () {
      final c = kBuiltInDarkSpec.colors;
      expect(kBuiltInDarkSpec.brightness, ThemeBrightness.dark);
      expect(c.background, const Color(0xFF07070D));
      expect(c.surfaceLow, const Color(0xFF0F1018));
      expect(c.surfaceContainer, const Color(0xFF13141C));
      expect(c.surfaceHigh, const Color(0xFF1A1C26));
      expect(c.outline, const Color(0xFF4B5064));
      expect(c.outlineVariant, const Color(0xFF24262F));
      expect(c.onSurface, const Color(0xFFF3F4F8));
      expect(c.onSurfaceVariant, const Color(0xFF8A90A4));
      expect(c.accent, AppColors.accent);
      expect(c.secondary, AppColors.secondary);
      expect(c.error, AppColors.error);
    });

    test('kBuiltInLightSpec reproduces the historical light palette', () {
      final c = kBuiltInLightSpec.colors;
      expect(kBuiltInLightSpec.brightness, ThemeBrightness.light);
      expect(c.background, const Color(0xFFF7F7FA));
      expect(c.surfaceLow, const Color(0xFFF1F2F5));
      expect(c.surfaceContainer, const Color(0xFFFFFFFF));
      expect(c.surfaceHigh, const Color(0xFFFAFAFC));
      expect(c.outline, const Color(0xFF8E92A2));
      expect(c.outlineVariant, const Color(0xFFE1E3E8));
      expect(c.onSurface, const Color(0xFF0B0C14));
      expect(c.onSurfaceVariant, const Color(0xFF5B6170));
    });

    test('built-in specs survive a JSON round-trip unchanged', () {
      expect(ThemeSpec.fromJson(kBuiltInDarkSpec.toJson()), kBuiltInDarkSpec);
      expect(ThemeSpec.fromJson(kBuiltInLightSpec.toJson()), kBuiltInLightSpec);
    });
  });
}
