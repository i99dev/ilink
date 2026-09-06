import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/app/gate/app_gate.dart';

void main() {
  group('onboardingOutcome (mandatory onboarding)', () {
    test('settings not loaded → loading', () {
      expect(
        onboardingOutcome(settingsLoaded: false, onboardingCompletedAt: null),
        isA<GateLoading>(),
      );
    });

    test('loaded + never onboarded → blocks', () {
      expect(
        onboardingOutcome(settingsLoaded: true, onboardingCompletedAt: null),
        isA<GateBlock>(),
      );
    });

    test('loaded + onboarded → passes', () {
      expect(
        onboardingOutcome(
          settingsLoaded: true,
          onboardingCompletedAt: DateTime(2026, 5, 24),
        ),
        isA<GatePass>(),
      );
    });
  });

  group('kPostSettingsGates ordering', () {
    test('local startup requires onboarding without a cloud login gate', () {
      expect(kPostSettingsGates.map((s) => s.id).toList(), [
        OnboardingGateStep.kId,
      ]);
    });
  });
}
