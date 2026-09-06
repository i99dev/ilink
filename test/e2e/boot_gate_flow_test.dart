/// E2E — the app entry gate.
///
/// `lib/main.dart`'s private `_Gate.build` is the navigational spine of
/// the whole app: it watches `settingsProvider` and routes
///
///   loading                       → spinner
///   data, onboardingCompletedAt==∅ → OnboardingScreen
///   data, onboardingCompletedAt!=∅ → DashShell
///
/// That contract was untested end to end — nothing asserted that a
/// fresh install lands on onboarding and a returning user lands on the
/// shell, through the *real* screens and the *real* provider graph.
/// The `BootGate` spine mirror lives in the shared harness so every
/// flow test reuses one copy.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/onboarding/presentation/onboarding_screen.dart';
import 'package:ilink/features/shell/presentation/dash_shell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../support/e2e_harness.dart';

void main() {
  testWidgets('fresh install → onboarding screen mounts', (tester) async {
    await pumpE2E(tester, const BootGate(), seed: settingsFresh());

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(DashShell), findsNothing);
  });

  testWidgets('returning user (onboarding complete) → DashShell mounts', (
    tester,
  ) async {
    // DashShell carries a perpetual rotator/HUD animation — never
    // settles — so pump bounded frames instead.
    await pumpE2E(
      tester,
      const BootGate(),
      seed: settingsOnboarded(),
      settle: false,
    );

    expect(find.byType(DashShell), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('gate flips live when onboarding completes mid-session', (
    tester,
  ) async {
    await pumpE2E(tester, const BootGate(), seed: settingsFresh());
    expect(find.byType(OnboardingScreen), findsOneWidget);

    // Simulate the onboarding controller persisting completion: write
    // through the real settingsProvider notifier, exactly as the app
    // does when the user finishes onboarding.
    final ctx = tester.element(find.byType(BootGate));
    final container = ProviderScope.containerOf(ctx);
    await container
        .read(settingsProvider.notifier)
        .save(
          AppSettings.empty.copyWith(
            onboardingCompletedAt: DateTime.utc(2026, 5, 19),
          ),
        );
    // Gate rebuilds to DashShell (perpetual animation → bounded pump).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(DashShell), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
  });
}
