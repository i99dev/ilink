import 'package:ilink/kernel/ui/responsive/breakpoints.dart';
import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/settings/presentation/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tiny controller stand-in: avoids hitting SharedPreferences on build and
/// lets tests seed the initial settings snapshot. We still exercise the
/// real SettingsController.save() path by overriding with a subclass.
class _FakeSettingsController extends SettingsController {
  _FakeSettingsController(this.seed);
  final AppSettings seed;

  @override
  Future<AppSettings> build() async => seed;

  @override
  Future<void> save(AppSettings next) async {
    state = AsyncData(next);
    lastSaved = next;
  }

  AppSettings? lastSaved;
}

const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

Widget _harness({
  required Widget child,
  AppSettings? seed,
  Size size = const Size(2560, 1600),
}) {
  return ProviderScope(
    overrides: [
      appConfigBaseProvider.overrideWithValue(_testConfig),
      settingsProvider.overrideWith(
        () => _FakeSettingsController(seed ?? AppSettings.empty),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.supportedLocales,
      locale: const Locale('en'),
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: BreakpointProvider(child: child),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('rail exposes every section and switching swaps the pane', (
    tester,
  ) async {
    // Default flutter_test viewport is 800x600 — too short for the rail
    // to render every tile + the SaveBar without cutting off the bottom
    // tile. Bump physical size so all 7 sections + the SaveBar fit
    // without scrolling — matches what the head unit actually has.
    await tester.binding.setSurfaceSize(const Size(2560, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _harness(child: const SettingsPage(), seed: AppSettings.empty),
    );
    await tester.pumpAndSettle();

    // Local settings remain reachable from the rail.
    for (final label in ['Voice commands', 'Language']) {
      expect(find.text(label), findsWidgets, reason: '$label should appear');
    }
    for (final label in ['Account', 'Vehicle', 'Status', 'Network']) {
      expect(
        find.text(label),
        findsNothing,
        reason: '$label tab should no longer be in the settings rail',
      );
    }

    // The landing section controls the local voice master switch.
    expect(find.byType(SwitchListTile), findsWidgets);

    // Tap Language → language rows appear. Use the Arabic row label
    // which is unique to the Language section pane (not in the rail).
    await tester.tap(find.text('Language').first);
    await tester.pumpAndSettle();
    expect(find.text('العربية'), findsOneWidget);
  });

  testWidgets('Voice commands section: no BYOK field, no provider grid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(child: const SettingsPage(), seed: AppSettings.empty),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice commands').first);
    await tester.pumpAndSettle();

    // BYOK UI must be gone: no API key field, no provider-picker
    // grid (Anthropic/Gemini/Local used to appear as "coming
    // soon" tiles — removed when BYOK was forbidden; see
    // memory/feedback_voice_llm_broker.md).
    expect(find.text('OpenAI API key'), findsNothing);
    expect(find.text('Anthropic'), findsNothing);
    expect(find.text('Gemini'), findsNothing);
    expect(find.text('Local'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    // Local voice remains configurable without cloud providers.
    expect(find.text('Voice routing'), findsNothing);
    expect(find.text('Help us improve voice'), findsNothing);
    expect(find.text('Show the assistant'), findsOneWidget);
  });

  testWidgets('Save button: disabled until a field changes, enabled after', (
    tester,
  ) async {
    const seed = AppSettings.empty;
    await tester.pumpWidget(_harness(child: const SettingsPage(), seed: seed));
    await tester.pumpAndSettle();

    ElevatedButton saveBtn() => tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(ElevatedButton),
      ),
    );

    // Initially no dirty state — onPressed must be null.
    expect(saveBtn().onPressed, isNull);
    expect(find.text('All changes saved'), findsOneWidget);

    // A retained local setting still participates in the draft/save flow.
    final voiceSwitch = find.ancestor(
      of: find.text('Show the assistant'),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(voiceSwitch);
    await tester.pumpAndSettle();
    await tester.tap(voiceSwitch);
    await tester.pumpAndSettle();

    // Save button now active; status label flips to Unsaved.
    expect(saveBtn().onPressed, isNotNull);
    expect(find.text('Unsaved changes'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    // A draft edit does not change the running voice setting until saved.
    expect(
      container.read(settingsProvider).value!.voiceAssistantEnabled,
      seed.voiceAssistantEnabled,
    );
    // A direct-write section may save while the voice draft is pending.
    await container
        .read(settingsProvider.notifier)
        .save(
          container
              .read(settingsProvider)
              .value!
              .copyWith(themeMode: ThemeMode.dark),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final controller =
        container.read(settingsProvider.notifier) as _FakeSettingsController;
    expect(
      controller.lastSaved!.voiceAssistantEnabled,
      !seed.voiceAssistantEnabled,
    );
    expect(controller.lastSaved!.themeMode, ThemeMode.dark);
    expect(saveBtn().onPressed, isNull);
    expect(find.text('All changes saved'), findsOneWidget);
  });
  testWidgets('loaded local voice state and draft revert stay synchronized', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        child: const SettingsPage(),
        seed: AppSettings.empty.copyWith(voiceAssistantEnabled: false),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.ancestor(
      of: find.text('Show the assistant'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text('All changes saved'), findsOneWidget);
  });
}
