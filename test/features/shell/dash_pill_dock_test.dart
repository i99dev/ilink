import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/voice/data/voice_service_bridge.dart';
import 'package:ilink/features/shell/presentation/dash_shell.dart'
    show visibleScreensProvider;
import 'package:ilink/features/shell/presentation/widgets/dash_pill_dock.dart';
import 'package:ilink/features/shell/state/active_screen_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_voice_service_bridge.dart';

const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

/// Widget tests for the dock. Keep assertions on observable behaviour —
/// tap switches the active screen, indicator moves. The mic moved out
/// of the dock (now [FloatingMic] anchored to the driver-side corner of
/// [DashShell]); the dock is nav-icons-only.
/// Pixel-perfect styling is not in scope here; the animated indicator's
/// internals are tested by frame-stepping without pixel comparisons.
void main() {
  Widget harness(
    Widget child, {
    List<DashScreen> screens = const [
      DashScreen.home,
      DashScreen.miniApps,
      DashScreen.radio,
    ],
  }) {
    return ProviderScope(
      overrides: [
        appConfigBaseProvider.overrideWithValue(_testConfig),
        voiceServiceBridgeProvider.overrideWithValue(FakeVoiceServiceBridge()),
        // Dock renders based on this provider; override so the tests
        // don't depend on SharedPreferences / SettingsController being
        // wired up in a unit-test harness.
        visibleScreensProvider.overrideWithValue(screens),
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
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('renders nav icons only — mic moved to FloatingMic', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const DashPillDock()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.dashboard_rounded), findsOneWidget);
    expect(find.byIcon(Icons.apps_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_rounded), findsOneWidget);
    // Media + Map tabs were removed — their icons must not appear.
    expect(find.byIcon(Icons.headphones_rounded), findsNothing);
    expect(find.byIcon(Icons.map_rounded), findsNothing);
    // Mic is no longer part of the dock — see FloatingMic widget.
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
  });

  testWidgets('tapping a nav icon updates activeScreenProvider', (
    tester,
  ) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      harness(
        Consumer(
          builder: (_, r, _) {
            ref = r;
            return const DashPillDock();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(ref.read(activeScreenProvider), DashScreen.home);

    await tester.tap(find.byIcon(Icons.radio_rounded));
    await tester.pumpAndSettle();
    expect(ref.read(activeScreenProvider), DashScreen.radio);

    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    expect(ref.read(activeScreenProvider), DashScreen.miniApps);
  });

  testWidgets('indicator AnimatedPositioned slides on screen change', (
    tester,
  ) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      harness(
        Consumer(
          builder: (_, r, _) {
            ref = r;
            return const DashPillDock();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Grab the AnimatedPositioned starting offset.
    AnimatedPositioned firstPositioned() =>
        tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));
    final before = firstPositioned().left;

    ref.read(activeScreenProvider.notifier).go(DashScreen.radio);
    await tester.pump(); // build with new state, animation starts

    final mid = firstPositioned().left;
    expect(
      mid,
      isNot(before),
      reason: 'AnimatedPositioned should target a new left offset',
    );
    await tester.pumpAndSettle();
    // After settling, the indicator's target has advanced further than the
    // starting position.
    expect((firstPositioned().left ?? 0), greaterThan(before ?? -1));
  });

  testWidgets('Semantics expose button + selected state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(const DashPillDock()));
    await tester.pumpAndSettle();

    // Active nav item: button + selected. Inactive: button, not selected.
    // Use containsSemantics so extra flags (focusable, hasSelectedState)
    // added by Flutter's defaults don't fail the match.
    expect(
      tester.getSemantics(find.byIcon(Icons.dashboard_rounded)),
      isSemantics(isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.byIcon(Icons.radio_rounded)),
      isSemantics(isButton: true, isSelected: false),
    );
    handle.dispose();
  });
}
