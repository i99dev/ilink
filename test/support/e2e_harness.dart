/// Centralized end-to-end test harness.
///
/// Every widget/flow test in this repo previously re-declared its own
/// `const _testConfig = AppConfig(...)` plus a near-identical
/// `ProviderScope(overrides: [...])` + localized `MaterialApp`. That
/// duplication is exactly the kind of scatter the architecture aims to
/// avoid — so the standard edge-fakes + localized app shell live here,
/// once. A flow test should only have to say *what journey* it drives,
/// not re-wire the boot edges.
///
/// What this fakes (the platform-channel / network edges that can't run
/// headless): [AppConfig] (mockCar), the SDK [CarClient], the voice
/// service bridge, and [SettingsController] (seedable, no
/// SharedPreferences round-trip). Everything above those edges is the
/// real provider graph + real widgets — that's what makes it E2E and
/// not a mock theatre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not surfaced by the main flutter_riverpod barrel (3.3.1);
// it lives in the `misc` sub-barrel. Needed only to type `extraOverrides`.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/kernel/ui/responsive/breakpoints.dart';
import 'package:ilink/kernel/shell/shell_ops_coordinator.dart'
    show ShellOpsCoordinator;
import 'package:ilink/kernel/shell/shell_tool_bridge_provider.dart'
    show shellOpsCoordinatorProvider;
import 'package:ilink/sdk/car/client.dart';
import 'package:ilink/sdk/car/_transport/car_bridge.dart'
    show carBridgeProvider;
import 'package:ilink/sdk/car/providers.dart' show daemonReadyProvider;
import 'package:ilink/features/radio/providers.dart'
    show sharedPreferencesProvider;
import 'package:ilink/features/onboarding/presentation/onboarding_screen.dart';
import 'package:ilink/features/shell/presentation/dash_shell.dart';
import 'package:ilink/features/voice/data/voice_service_bridge.dart';

import 'fake_car_bridge.dart';
import 'fake_car_client.dart';
import 'fake_voice_service_bridge.dart';

/// The single canonical test config. `mockCar: true` keeps the SDK from
/// reaching for Android platform channels; ports are 0 so nothing dials.
const e2eTestConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

/// Seedable [SettingsController] — mirrors the pattern proven in
/// `settings_page_test.dart`. `save()` updates state synchronously and
/// records the last write so flow tests can assert persistence intent
/// without a SharedPreferences round-trip.
class SeedSettingsController extends SettingsController {
  SeedSettingsController(this.seed);

  final AppSettings seed;
  AppSettings? lastSaved;

  @override
  Future<AppSettings> build() async => seed;

  @override
  Future<void> save(AppSettings next) async {
    state = AsyncData(next);
    lastSaved = next;
  }
}

/// A completed-onboarding settings snapshot (gate → DashShell).
AppSettings settingsOnboarded() =>
    AppSettings.empty.copyWith(onboardingCompletedAt: DateTime.utc(2026, 1, 1));

/// A fresh-install settings snapshot (gate → OnboardingScreen).
AppSettings settingsFresh() => AppSettings.empty;

/// Build the standard E2E [ProviderScope] + localized [MaterialApp]
/// around [child].
///
/// - [seed]: initial settings snapshot. Defaults to onboarded.
/// - [carClient]: inject a pre-seeded fake to script car reads; a fresh
///   [FakeCarClient] is used when omitted.
/// - [extraOverrides]: per-flow overrides layered on top (e.g. a feature
///   catalog provider). Kept last so a flow can shadow a default.
/// - [size]: logical surface size. Defaults to the IVI viewport.
Widget e2eApp({
  required Widget child,
  required SharedPreferences prefs,
  AppSettings? seed,
  FakeCarClient? carClient,
  FakeVoiceServiceBridge? voiceBridge,
  List<Override> extraOverrides = const [],
  Size size = const Size(2560, 1600),
}) {
  return ProviderScope(
    overrides: [
      appConfigBaseProvider.overrideWithValue(e2eTestConfig),
      // Mirror main.dart: the synchronous prefs provider must be fed a
      // pre-loaded instance or every feature that reads it throws.
      sharedPreferencesProvider.overrideWithValue(prefs),
      settingsProvider.overrideWith(
        () => SeedSettingsController(seed ?? settingsOnboarded()),
      ),
      carClientProvider.overrideWithValue(carClient ?? FakeCarClient()),
      // Fake the transport so nothing dials ADB and — critically — the
      // real CarBridge._guard 3s timeout timer never gets scheduled.
      carBridgeProvider.overrideWithValue(FakeCarBridge()),
      // daemonReadyProvider polls transport.daemonStatus() forever on a
      // 2s loop; left live it leaks a pending timer past test teardown.
      // Daemon health is a transport signal — fake it flat.
      daemonReadyProvider.overrideWith((ref) => Stream.value(true)),
      // Every shell-backed tool (connectivity strip, network sheet, …)
      // funnels through this coordinator. The real exec is a
      // MethodChannel that never resolves headless, so its
      // `.timeout()` timer leaks past teardown. An instant empty exec
      // makes the timeout self-cancel and gives tools a benign read —
      // one override neutralizes the whole shell-tool family.
      shellOpsCoordinatorProvider.overrideWithValue(
        ShellOpsCoordinator(exec: (_) async => ''),
      ),
      voiceServiceBridgeProvider.overrideWithValue(
        voiceBridge ?? FakeVoiceServiceBridge(),
      ),
      ...extraOverrides,
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
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

/// Pump [child] inside [e2eApp]. Sets the surface size + mock
/// SharedPreferences and tears them down. Flow tests interact via the
/// [tester].
///
/// [settle]: when true (default) waits for all animations to quiesce.
/// Screens with a perpetual animation (the voice example rotator / HUD
/// on `DashShell`) never settle, so those flows pass `settle: false` and
/// the harness pumps a bounded number of frames instead.
Future<void> pumpE2E(
  WidgetTester tester,
  Widget child, {
  AppSettings? seed,
  FakeCarClient? carClient,
  FakeVoiceServiceBridge? voiceBridge,
  List<Override> extraOverrides = const [],
  Size size = const Size(2560, 1600),
  bool settle = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    e2eApp(
      child: child,
      prefs: prefs,
      seed: seed,
      carClient: carClient,
      voiceBridge: voiceBridge,
      extraOverrides: extraOverrides,
      size: size,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Enough frames for the gate → screen transition + first layout,
    // without waiting on a perpetual animation.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }
}

/// Verbatim mirror of `lib/main.dart`'s private `_Gate.build` settings
/// branch — the navigational spine of the whole app:
///
///   loading                        → spinner
///   data, onboardingCompletedAt==∅  → OnboardingScreen
///   data, onboardingCompletedAt!=∅  → DashShell
///
/// `_Gate` is private to main.dart so it can't be imported; this mirror
/// lives in the harness (one place) instead of being copy-pasted into
/// each flow test. If the real spine changes, change this with it — the
/// E2E suite then guards the new contract.
class BootGate extends ConsumerWidget {
  const BootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return settings.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('err: $e'))),
      data: (s) => s.onboardingCompletedAt == null
          ? const OnboardingScreen()
          : const DashShell(),
    );
  }
}
