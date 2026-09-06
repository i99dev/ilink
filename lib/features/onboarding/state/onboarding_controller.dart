import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/locale_controller.dart';
import '../../../kernel/settings/app_settings.dart';
import '../domain/permission_kind.dart';
import 'permission_service_provider.dart';

/// Snapshot of the onboarding UI's state. Immutable, value-equal so
/// `ref.watch(...select(...))` short-circuits the right rebuilds.
class OnboardingState {
  const OnboardingState({
    required this.consents,
    required this.results,
    required this.isFinishing,
  });

  /// Toggle position per permission. All true on first build (the
  /// privacy-respecting default that still lets every feature work).
  final Map<PermissionKind, bool> consents;

  /// Per-permission outcome of the last `finish()` run. Empty before
  /// the user presses Continue; populated as each request resolves so
  /// the UI can stamp a status pill on each tile.
  final Map<PermissionKind, PermissionRequestResult> results;

  /// True while the controller is iterating through requests + the
  /// final `SettingsController.save()`. UI disables Continue + shows a
  /// spinner.
  final bool isFinishing;

  OnboardingState copyWith({
    Map<PermissionKind, bool>? consents,
    Map<PermissionKind, PermissionRequestResult>? results,
    bool? isFinishing,
  }) => OnboardingState(
    consents: consents ?? this.consents,
    results: results ?? this.results,
    isFinishing: isFinishing ?? this.isFinishing,
  );

  static OnboardingState initial() => OnboardingState(
    consents: {for (final k in PermissionKind.values) k: true},
    results: const {},
    isFinishing: false,
  );

  @override
  bool operator ==(Object other) =>
      other is OnboardingState &&
      _mapEq(other.consents, consents) &&
      _mapEq(other.results, results) &&
      other.isFinishing == isFinishing;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(consents.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAll(results.entries.map((e) => Object.hash(e.key, e.value))),
    isFinishing,
  );

  static bool _mapEq<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Drives the onboarding screen. UI calls into these methods; state
/// flows back through `state` for the screen to render.
class OnboardingController extends Notifier<OnboardingState> {
  @override
  OnboardingState build() => OnboardingState.initial();

  /// Flip a single permission toggle. UI binds this to `Switch.adaptive`.
  void toggle(PermissionKind kind, bool value) {
    state = state.copyWith(consents: {...state.consents, kind: value});
  }

  /// Locale picker proxy — keeps the UI from reaching into
  /// `localeControllerProvider` directly so all onboarding actions
  /// flow through one entry point.
  Future<void> setLocale(AppLang lang) async {
    await ref.read(localeControllerProvider.notifier).set(lang);
  }

  /// Triggers OS permission requests for whichever toggles are still
  /// on, records each result, then marks onboarding complete in
  /// settings. Denied requests don't abort — the gate flips regardless
  /// so the user lands in the app and can opt back in later.
  Future<void> finish() async {
    if (state.isFinishing) return;
    state = state.copyWith(isFinishing: true, results: const {});

    final service = ref.read(permissionServiceProvider);
    final results = <PermissionKind, PermissionRequestResult>{};
    for (final kind in PermissionKind.values) {
      final enabled = state.consents[kind] ?? false;
      if (!enabled) {
        results[kind] = PermissionRequestResult.skipped;
        continue;
      }
      try {
        results[kind] = await service.request(kind);
      } catch (_) {
        // A platform-channel hiccup shouldn't trap the user on the
        // onboarding screen. Treat as denied + move on; user can
        // re-grant from system settings later.
        results[kind] = PermissionRequestResult.denied;
      }
      state = state.copyWith(results: Map.unmodifiable(results));
    }

    final settingsCtl = ref.read(settingsProvider.notifier);
    // Await `.future` (not `.value`) to guarantee the AsyncNotifier's
    // initial build() has resolved — otherwise a concurrent build
    // overwrites our save() and the onboarding flag never sticks.
    final current = await ref.read(settingsProvider.future);
    await settingsCtl.save(
      current.copyWith(onboardingCompletedAt: DateTime.now()),
    );

    // The gate watches settingsProvider — once `save` lands, the gate
    // rebuilds with `onboardingCompletedAt != null` and swaps to
    // DashShell. We update isFinishing to false too so any brief
    // teardown frame still looks coherent.
    state = state.copyWith(isFinishing: false);
  }
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, OnboardingState>(
      OnboardingController.new,
    );
