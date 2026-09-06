import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/themes/data/built_in_themes.dart';
import 'package:ilink/features/themes/data/theme_repository.dart';
import 'package:ilink/features/themes/state/theme_providers.dart';
import 'package:ilink/features/themes/state/theme_repository_provider.dart';
import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/kernel/ui/theme/app_theme.dart';
import 'package:ilink/kernel/ui/theme/theme_spec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

/// A spec authored as JSON exactly per THEMES_CONTRACT.md §2, then fed
/// through the real parse + theme-build path the app uses at runtime.
final _neonJson = <String, Object?>{
  'schema': 1,
  'brightness': 'dark',
  'colors': {
    'background': '#050507',
    'surfaceLow': '#0B0B12',
    'surfaceContainer': '#111119',
    'surfaceHigh': '#181826',
    'outline': '#6B5C8A',
    'outlineVariant': '#2A2438',
    'onSurface': '#F6F2FF',
    'onSurfaceVariant': '#9B8FB8',
    'accent': '#FF2E97',
    'secondary': '#22D3EE',
    'error': '#E76F51',
  },
  'shape': {'cardRadius': 16, 'buttonRadius': 10, 'inputRadius': 10},
};

void main() {
  group('AppTheme.fromSpec end-to-end render', () {
    testWidgets('renders a parsed ThemeSpec into the real ColorScheme', (
      tester,
    ) async {
      // Parse JSON → ThemeSpec → ThemeData → pump a real widget under it.
      final spec = ThemeSpec.fromJson(_neonJson);
      final theme = AppTheme.fromSpec(spec);

      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                captured = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final cs = Theme.of(captured).colorScheme;
      // The rendered ColorScheme matches the spec's tokens.
      expect(cs.primary, const Color(0xFFFF2E97)); // accent → primary
      expect(cs.secondary, const Color(0xFF22D3EE));
      expect(cs.surface, const Color(0xFF050507));
      expect(cs.onSurface, const Color(0xFFF6F2FF));

      // The actual Scaffold paints the spec background.
      final scaffold = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(Scaffold),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(scaffold.color, const Color(0xFF050507));
      expect(
        Theme.of(captured).scaffoldBackgroundColor,
        const Color(0xFF050507),
      );
    });
  });

  group('live theme apply via settingsProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
      'switching activeThemeId re-resolves ThemeData with no restart',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            appConfigBaseProvider.overrideWithValue(_testConfig),
            appConfigProvider.overrideWithValue(_testConfig),
            themeRepositoryProvider.overrideWithValue(
              const BuiltInThemeRepository(),
            ),
          ],
        );
        addTearDown(container.dispose);
        // Hydrate settings (empty → inert default).
        await container.read(settingsProvider.future);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Consumer(
              builder: (context, ref, _) {
                final resolved = ref.watch(activeThemeDataProvider('en'));
                return MaterialApp(
                  theme: resolved.light,
                  darkTheme: resolved.dark,
                  themeMode: ThemeMode.dark,
                  home: Builder(
                    builder: (context) {
                      final cs = Theme.of(context).colorScheme;
                      return Scaffold(
                        body: Text('accent:${cs.primary.toARGB32()}'),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Inert default: dark theme = built-in Midnight → AppColors.accent.
        final builtInDark = AppTheme.dark();
        final defaultAccent = builtInDark.colorScheme.primary.toARGB32();
        expect(find.text('accent:$defaultAccent'), findsOneWidget);

        // User picks Neon → activeThemeId persisted → provider re-resolves.
        final s = container.read(settingsProvider).value!;
        await container
            .read(settingsProvider.notifier)
            .save(s.copyWith(activeThemeId: kNeonThemeId));
        await tester.pumpAndSettle();

        // Live apply: the rendered accent is now the Neon spec's accent.
        final neonAccent = _neonAccent();
        expect(find.text('accent:$neonAccent'), findsOneWidget);
        // ...and it's different from the default (real change happened).
        expect(neonAccent, isNot(defaultAccent));
      },
    );
  });

  group('a selected theme owns the app brightness', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          appConfigBaseProvider.overrideWithValue(_testConfig),
          appConfigProvider.overrideWithValue(_testConfig),
          themeRepositoryProvider.overrideWithValue(
            const BuiltInThemeRepository(),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'no theme selected → inert (null mode, built-in light/dark)',
      () async {
        final c = container();
        await c.read(settingsProvider.future);
        final resolved = c.read(activeThemeDataProvider('en'));
        expect(resolved.mode, isNull, reason: 'default follows user themeMode');
        expect(resolved.light.brightness, Brightness.light);
        expect(resolved.dark.brightness, Brightness.dark);
      },
    );

    test('light theme forces light mode and themes BOTH slots', () async {
      final c = container();
      final s = await c.read(settingsProvider.future);
      await c
          .read(settingsProvider.notifier)
          .save(s.copyWith(activeThemeId: kDaylightThemeId));
      final resolved = c.read(activeThemeDataProvider('en'));
      // Picking a light theme lights up the car regardless of the prior
      // System/Light/Dark setting: forced light mode + both slots light.
      expect(resolved.mode, ThemeMode.light);
      expect(resolved.light.brightness, Brightness.light);
      expect(resolved.dark.brightness, Brightness.light);
    });

    test('dark theme (Neon) forces dark mode and themes BOTH slots', () async {
      final c = container();
      final s = await c.read(settingsProvider.future);
      await c
          .read(settingsProvider.notifier)
          .save(s.copyWith(activeThemeId: kNeonThemeId));
      final resolved = c.read(activeThemeDataProvider('en'));
      expect(resolved.mode, ThemeMode.dark);
      final neonAccent = _neonAccent();
      expect(resolved.light.colorScheme.primary.toARGB32(), neonAccent);
      expect(resolved.dark.colorScheme.primary.toARGB32(), neonAccent);
    });
  });
}

int _neonAccent() {
  final neon = kBuiltInThemes.firstWhere((t) => t.id == kNeonThemeId);
  return neon.spec.colors.accent.toARGB32();
}
