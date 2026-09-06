/// E2E — the first-run onboarding journey, end to end through the gate.
///
///   fresh install → OnboardingScreen → tap "finish" →
///   permissions requested → onboarding marked complete in settings →
///   gate rebuilds → DashShell
///
/// This is the single most important first-touch flow and nothing
/// asserted it whole: that tapping the real CTA on the real
/// `OnboardingScreen` drives the real `OnboardingController.finish()`,
/// persists `onboardingCompletedAt`, and flips the real boot gate to
/// the shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/onboarding/data/permission_service.dart';
import 'package:ilink/features/onboarding/domain/permission_kind.dart';
import 'package:ilink/features/onboarding/presentation/onboarding_screen.dart';
import 'package:ilink/features/onboarding/state/permission_service_provider.dart';
import 'package:ilink/features/shell/presentation/dash_shell.dart';

import '../support/e2e_harness.dart';

/// Grants every permission instantly — keeps the flow deterministic and
/// off the real `permission_handler` platform channel.
class _GrantAllPermissionService implements PermissionService {
  const _GrantAllPermissionService();
  @override
  Future<PermissionRequestResult> request(PermissionKind kind) async =>
      PermissionRequestResult.granted;
}

void main() {
  testWidgets('fresh install → finish onboarding → gate flips to DashShell', (
    tester,
  ) async {
    await pumpE2E(
      tester,
      const BootGate(),
      seed: settingsFresh(),
      extraOverrides: [
        permissionServiceProvider.overrideWithValue(
          const _GrantAllPermissionService(),
        ),
      ],
    );

    // Gate routed a fresh install to onboarding.
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(DashShell), findsNothing);

    // Tap the real finish CTA (ElevatedButton.icon → ElevatedButton).
    final finishBtn = find.byType(ElevatedButton);
    expect(finishBtn, findsOneWidget);
    await tester.ensureVisible(finishBtn);
    await tester.tap(finishBtn);

    // finish() awaits: permission requests (faked, instant) →
    // settingsProvider.future (seed resolves) → save(). Pump bounded
    // frames to drain those awaits, then the gate rebuilds onto the
    // perpetually-animating DashShell (so no pumpAndSettle).
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // The whole spine moved: settings persisted, gate swapped screens.
    expect(find.byType(DashShell), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);

    final ctx = tester.element(find.byType(DashShell));
    final container = ProviderScope.containerOf(ctx);
    final controller =
        container.read(settingsProvider.notifier) as SeedSettingsController;
    expect(
      controller.lastSaved?.onboardingCompletedAt,
      isNotNull,
      reason:
          'finish() must persist onboardingCompletedAt — that is '
          'what the gate watches to advance.',
    );
  });

  testWidgets('declining a permission still completes onboarding', (
    tester,
  ) async {
    await pumpE2E(
      tester,
      const BootGate(),
      seed: settingsFresh(),
      extraOverrides: [
        permissionServiceProvider.overrideWithValue(
          const _DenyAllPermissionService(),
        ),
      ],
    );
    expect(find.byType(OnboardingScreen), findsOneWidget);

    await tester.ensureVisible(find.byType(ElevatedButton));
    await tester.tap(find.byType(ElevatedButton));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Contract: denied permissions do NOT trap the user on onboarding —
    // the gate flips regardless so they can opt back in later.
    expect(find.byType(DashShell), findsOneWidget);
  });
}

class _DenyAllPermissionService implements PermissionService {
  const _DenyAllPermissionService();
  @override
  Future<PermissionRequestResult> request(PermissionKind kind) async =>
      PermissionRequestResult.denied;
}
