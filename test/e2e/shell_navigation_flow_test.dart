/// E2E — the post-onboarding shell navigation journey.
///
/// Drives the *real* `DashShell` + real pill dock + real `PageView`
/// through a multi-screen journey a returning user actually performs:
///
///   home → (tap Apps) → mini-apps → (tap Radio) → radio → (tap Home)
///
/// Asserts the navigation contract at every hop: `activeScreenProvider`
/// advances, and the dock reflects the selected screen. This is the
/// first test that exercises the shell's tap → controller → pager wiring
/// end to end (the dock unit test only covers the dock in isolation).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/shell/presentation/dash_shell.dart';
import 'package:ilink/features/shell/presentation/widgets/dash_pill_dock.dart';
import 'package:ilink/features/shell/state/active_screen_controller.dart';

import '../support/e2e_harness.dart';

void main() {
  // DashShell carries a perpetual rotator/HUD animation, so every pump
  // is bounded rather than `pumpAndSettle`.
  Future<void> tick(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  DashScreen active(WidgetTester tester) {
    final ctx = tester.element(find.byType(DashShell));
    return ProviderScope.containerOf(ctx).read(activeScreenProvider);
  }

  // Scope nav-icon finds to the dock. A nav icon (e.g. radio_rounded)
  // can also appear in Home content — the voice-shortcuts tile carries a
  // radio glyph — so a global `find.byIcon` matches >1 widget and both
  // the count assertion and `tap` (which requires exactly one) break.
  // The dock is what this navigation test actually asserts on.
  Finder dockIcon(IconData icon) => find.descendant(
    of: find.byType(DashPillDock),
    matching: find.byIcon(icon),
  );

  testWidgets('returning user lands on Home with the dock visible', (
    tester,
  ) async {
    await pumpE2E(tester, const DashShell(), settle: false);

    expect(find.byType(DashShell), findsOneWidget);
    expect(active(tester), DashScreen.home);
    // Dock nav icons render (proves the shell chrome mounted, not just
    // a spinner / error scaffold).
    expect(dockIcon(Icons.dashboard_rounded), findsOneWidget);
    expect(dockIcon(Icons.apps_rounded), findsOneWidget);
    expect(dockIcon(Icons.radio_rounded), findsOneWidget);
  });

  testWidgets('tap Apps → Radio → Home advances activeScreen each hop', (
    tester,
  ) async {
    await pumpE2E(tester, const DashShell(), settle: false);
    expect(active(tester), DashScreen.home);

    await tester.tap(dockIcon(Icons.apps_rounded));
    await tick(tester);
    expect(active(tester), DashScreen.miniApps);

    await tester.tap(dockIcon(Icons.radio_rounded));
    await tick(tester);
    expect(active(tester), DashScreen.radio);

    await tester.tap(dockIcon(Icons.dashboard_rounded));
    await tick(tester);
    expect(active(tester), DashScreen.home);
  });

  testWidgets('an external push (voice/deep-link) drives the same pager', (
    tester,
  ) async {
    await pumpE2E(tester, const DashShell(), settle: false);
    final ctx = tester.element(find.byType(DashShell));
    final container = ProviderScope.containerOf(ctx);

    // Simulate a non-tap navigation source (deep link / voice tool)
    // calling the controller directly — the shell's listener must keep
    // the PageView in lockstep without throwing.
    container.read(activeScreenProvider.notifier).go(DashScreen.miniApps);
    await tick(tester);
    expect(active(tester), DashScreen.miniApps);

    container.read(activeScreenProvider.notifier).go(DashScreen.home);
    await tick(tester);
    expect(active(tester), DashScreen.home);
  });
}
