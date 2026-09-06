import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/onboarding/presentation/onboarding_screen.dart';
import 'package:ilink/kernel/settings/app_settings.dart';

/// Declarative boot-gate pipeline.
///
/// Each gate is a PURE predicate over providers (no side effects), so the
/// boot order lives in ONE list ([kPostSettingsGates]) and every step is a
/// trivially-testable unit. The host (main's `_Gate`) evaluates them in
/// order and renders the FIRST non-pass screen, or the shell when they all
/// pass.
///
/// NB: the **license** gate runs earlier than these — pre-settings,
/// pre-boot-sequence — directly in `_Gate`, because it must clear before
/// the boot sequence kicks. These are the gates that apply AFTER settings
/// hydrate (they read `settings` / `authStatus`).
sealed class GateOutcome {
  const GateOutcome();
}

/// This gate is satisfied — move on to the next.
class GatePass extends GateOutcome {
  const GatePass();
}

/// This gate can't decide yet (a provider is still resolving). The host
/// shows [screen] (or a default spinner) and re-evaluates on the next
/// provider tick.
class GateLoading extends GateOutcome {
  const GateLoading([this.screen]);
  final Widget? screen;
}

/// This gate blocks: the host renders [screen] full-screen until the
/// gate's inputs change and it re-evaluates to pass.
class GateBlock extends GateOutcome {
  const GateBlock(this.screen);
  final Widget screen;
}

abstract class AppGateStep {
  const AppGateStep();

  /// Stable id for telemetry + tests.
  String get id;

  /// Pure: providers in → outcome out. Must only `ref.watch`.
  GateOutcome evaluate(WidgetRef ref);
}

/// Pure decision for the onboarding gate (testable without a Ref).
GateOutcome onboardingOutcome({
  required bool settingsLoaded,
  required DateTime? onboardingCompletedAt,
}) {
  if (!settingsLoaded) return const GateLoading(); // still hydrating
  return onboardingCompletedAt == null
      ? const GateBlock(OnboardingScreen())
      : const GatePass();
}

/// Mandatory first-run onboarding (OS permissions + locale). Blocks until
/// `onboardingCompletedAt` is set.
class OnboardingGateStep extends AppGateStep {
  const OnboardingGateStep();

  static const kId = 'onboarding';

  @override
  String get id => kId;

  @override
  GateOutcome evaluate(WidgetRef ref) {
    final s = ref.watch(settingsProvider).value;
    return onboardingOutcome(
      settingsLoaded: s != null,
      onboardingCompletedAt: s?.onboardingCompletedAt,
    );
  }
}

/// Canonical, ordered list of the post-settings boot gates. Adding a gate
/// (e.g. a future first-table-sync gate) is a one-line entry here.
const List<AppGateStep> kPostSettingsGates = [OnboardingGateStep()];

/// Evaluate [steps] in order; return the first non-pass outcome, or `null`
/// when every gate passes (the host then renders the shell).
GateOutcome? firstBlockingGate(WidgetRef ref, List<AppGateStep> steps) {
  for (final step in steps) {
    final outcome = step.evaluate(ref);
    if (outcome is! GatePass) return outcome;
  }
  return null;
}
