import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/features/onboarding/data/permission_service.dart';
import 'package:ilink/features/onboarding/domain/permission_kind.dart';
import 'package:ilink/features/onboarding/state/onboarding_controller.dart';
import 'package:ilink/features/onboarding/state/permission_service_provider.dart';
import 'package:ilink/kernel/settings/app_settings.dart';

// Compile-time AppConfig — onboarding reaches into settings, which
// reads appConfigProvider for the mockCar branch. Override both base
// and effective so the settings ↔ override cycle short-circuits.
const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,
  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

/// Records every `request()` call so the test can assert which
/// permissions actually got prompted versus skipped.
class _RecordingPermissionService implements PermissionService {
  final List<PermissionKind> requested = [];
  final Map<PermissionKind, PermissionRequestResult> outcomes;

  _RecordingPermissionService({
    Map<PermissionKind, PermissionRequestResult>? outcomes,
  }) : outcomes = outcomes ?? {};

  @override
  Future<PermissionRequestResult> request(PermissionKind kind) async {
    requested.add(kind);
    return outcomes[kind] ?? PermissionRequestResult.granted;
  }
}

class _ThrowingPermissionService implements PermissionService {
  @override
  Future<PermissionRequestResult> request(PermissionKind kind) =>
      throw Exception('platform channel boom');
}

ProviderContainer _container({required PermissionService service}) {
  return ProviderContainer(
    overrides: [
      permissionServiceProvider.overrideWithValue(service),
      appConfigBaseProvider.overrideWithValue(_testConfig),
      appConfigProvider.overrideWithValue(_testConfig),
    ],
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('initial state has all consents on, no results, not finishing', () {
    final c = _container(service: _RecordingPermissionService());
    addTearDown(c.dispose);

    final state = c.read(onboardingControllerProvider);
    expect(state.consents.values.every((v) => v == true), isTrue);
    expect(state.results, isEmpty);
    expect(state.isFinishing, isFalse);
    expect(state.consents.length, PermissionKind.values.length);
  });

  test('toggle flips a single consent without disturbing others', () {
    final c = _container(service: _RecordingPermissionService());
    addTearDown(c.dispose);

    c
        .read(onboardingControllerProvider.notifier)
        .toggle(PermissionKind.microphone, false);

    final state = c.read(onboardingControllerProvider);
    expect(state.consents[PermissionKind.microphone], isFalse);
    expect(state.consents[PermissionKind.location], isTrue);
    expect(state.consents[PermissionKind.notifications], isTrue);
  });

  test(
    'finish requests only enabled consents, skipped permissions never prompt',
    () async {
      final svc = _RecordingPermissionService();
      final c = _container(service: svc);
      addTearDown(c.dispose);

      c
          .read(onboardingControllerProvider.notifier)
          .toggle(PermissionKind.microphone, false);
      await c.read(onboardingControllerProvider.notifier).finish();

      // microphone was off → never requested.
      expect(svc.requested, isNot(contains(PermissionKind.microphone)));
      // others were on → both requested.
      expect(svc.requested, contains(PermissionKind.location));
      expect(svc.requested, contains(PermissionKind.notifications));

      final state = c.read(onboardingControllerProvider);
      expect(
        state.results[PermissionKind.microphone],
        PermissionRequestResult.skipped,
      );
      expect(
        state.results[PermissionKind.location],
        PermissionRequestResult.granted,
      );
    },
  );

  test('finish writes onboardingCompletedAt to settings', () async {
    final c = _container(service: _RecordingPermissionService());
    addTearDown(c.dispose);

    final before = await c.read(settingsProvider.future);
    expect(before.onboardingCompletedAt, isNull);

    await c.read(onboardingControllerProvider.notifier).finish();

    final after = c.read(settingsProvider).value;
    expect(after?.onboardingCompletedAt, isNotNull);
  });

  test('finish does not abort when a permission throws', () async {
    final c = _container(service: _ThrowingPermissionService());
    addTearDown(c.dispose);

    await c.read(onboardingControllerProvider.notifier).finish();

    final state = c.read(onboardingControllerProvider);
    // Every permission landed with a recorded denied result, none
    // were left as `idle` — the loop didn't bail mid-way.
    for (final k in PermissionKind.values) {
      expect(state.results[k], PermissionRequestResult.denied);
    }
    // And settings still got marked complete so the user isn't stuck.
    expect(c.read(settingsProvider).value?.onboardingCompletedAt, isNotNull);
  });

  test('finish blocks while running', () async {
    final svc = _RecordingPermissionService();
    final c = _container(service: svc);
    addTearDown(c.dispose);

    final f1 = c.read(onboardingControllerProvider.notifier).finish();
    // Second invocation while the first is in flight should no-op.
    await c.read(onboardingControllerProvider.notifier).finish();
    await f1;

    // Three permissions × one finish() call = three requests, not six.
    expect(svc.requested.length, PermissionKind.values.length);
  });

  test('clearOnboarding via copyWith puts the flag back to null', () async {
    final c = _container(service: _RecordingPermissionService());
    addTearDown(c.dispose);

    await c.read(onboardingControllerProvider.notifier).finish();
    expect(c.read(settingsProvider).value?.onboardingCompletedAt, isNotNull);

    final current = c.read(settingsProvider).value!;
    await c
        .read(settingsProvider.notifier)
        .save(current.copyWith(clearOnboarding: true));

    expect(c.read(settingsProvider).value?.onboardingCompletedAt, isNull);
  });
}
