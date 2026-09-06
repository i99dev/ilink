import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/themes/data/built_in_themes.dart';
import 'package:ilink/features/themes/data/theme_repository.dart';
import 'package:ilink/features/themes/presentation/widgets/themes_section.dart';
import 'package:ilink/features/themes/state/theme_repository_provider.dart';
import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

Widget _harness(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      localizationsDelegates: [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: SingleChildScrollView(child: ThemesSection())),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        appConfigBaseProvider.overrideWithValue(_testConfig),
        appConfigProvider.overrideWithValue(_testConfig),
        // Keep the gallery test network-free: production uses
        // ApiThemeRepository (floors to the same built-ins), but here we
        // pin the offline impl so no fetch is attempted.
        themeRepositoryProvider.overrideWithValue(
          const BuiltInThemeRepository(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('lists the bundled built-in themes with a built-in pill', (
    tester,
  ) async {
    final c = container();
    await c.read(settingsProvider.future);
    await tester.pumpWidget(_harness(c));
    await tester.pumpAndSettle();

    // All three built-ins render.
    expect(find.text('Midnight'), findsOneWidget);
    expect(find.text('Daylight'), findsOneWidget);
    expect(find.text('Neon'), findsOneWidget);
    // The "Built-in" pill appears for each (3 themes).
    expect(find.text('Built-in'), findsNWidgets(kBuiltInThemes.length));
  });

  testWidgets('default state marks Midnight active (inert default)', (
    tester,
  ) async {
    final c = container();
    await c.read(settingsProvider.future);
    await tester.pumpWidget(_harness(c));
    await tester.pumpAndSettle();

    // Empty activeThemeId → Midnight shown active → exactly one "Active".
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('tapping Apply on Neon persists activeThemeId', (tester) async {
    final c = container();
    await c.read(settingsProvider.future);
    await tester.pumpWidget(_harness(c));
    await tester.pumpAndSettle();

    // Find the Apply button inside the Neon card and tap it.
    final neonCard = find.ancestor(
      of: find.text('Neon'),
      matching: find.byType(InkWell),
    );
    final applyInNeon = find.descendant(
      of: neonCard.first,
      matching: find.widgetWithText(OutlinedButton, 'Apply'),
    );
    await tester.tap(applyInNeon.first);
    await tester.pumpAndSettle();

    // The setting persisted to the Neon id.
    expect(c.read(settingsProvider).value?.activeThemeId, kNeonThemeId);
    // The gallery now marks Neon active.
    expect(find.text('Active'), findsOneWidget);
  });
}
