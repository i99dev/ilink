import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/platform/launcher/launcher_bootstrap_controller.dart';
import 'package:ilink/platform/launcher/launcher_privilege_status.dart';

class _FakeChannel extends LauncherBootstrapChannel {
  _FakeChannel({
    this.grantOutcome,
    this.homeOutcome,
    this.delay = Duration.zero,
  }) : super();

  LauncherGrantOutcome? grantOutcome;
  LauncherDefaultHomeOutcome? homeOutcome;
  Duration delay;

  int grantCalls = 0;
  int homeCalls = 0;
  int? lastEnabled;

  @override
  Future<LauncherGrantOutcome> grantAll() async {
    grantCalls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return grantOutcome ?? const LauncherGrantOutcome(ok: true, results: []);
  }

  @override
  Future<void> setLauncherModeEnabled(bool enabled) async {
    lastEnabled = enabled ? 1 : 0;
  }

  @override
  Future<LauncherDefaultHomeOutcome> requestDefaultHome() async {
    homeCalls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return homeOutcome ??
        const LauncherDefaultHomeOutcome(ok: true, method: 'role_manager');
  }
}

ProviderContainer _container({LauncherBootstrapChannel? channel}) {
  final c = ProviderContainer(
    overrides: [
      if (channel != null)
        launcherBootstrapChannelProvider.overrideWithValue(channel),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('LauncherBootstrapController.grantAll', () {
    test(
      'sets busy while in flight, clears on completion, stores outcome',
      () async {
        final fake = _FakeChannel(
          grantOutcome: const LauncherGrantOutcome(
            ok: true,
            results: [
              LauncherGrantResult(key: 'readLogs', ok: true, output: ''),
            ],
          ),
          delay: const Duration(milliseconds: 20),
        );
        final c = _container(channel: fake);
        final controller = c.read(launcherBootstrapControllerProvider.notifier);
        final fut = controller.grantAll();
        // Busy reflects in-flight state immediately after the call.
        expect(c.read(launcherBootstrapControllerProvider).busy, isTrue);
        final outcome = await fut;
        expect(outcome.ok, isTrue);
        expect(outcome.results.single.key, 'readLogs');
        final post = c.read(launcherBootstrapControllerProvider);
        expect(post.busy, isFalse);
        expect(post.lastGrant?.ok, isTrue);
      },
    );

    test(
      'overlapping calls return the cached lastGrant without re-firing',
      () async {
        final fake = _FakeChannel(delay: const Duration(milliseconds: 30));
        final c = _container(channel: fake);
        final controller = c.read(launcherBootstrapControllerProvider.notifier);
        final f1 = controller.grantAll();
        final f2 = controller.grantAll();
        await Future.wait([f1, f2]);
        // Second call short-circuited because busy was already true.
        expect(fake.grantCalls, 1);
      },
    );

    test('invalidates launcherPrivilegeStatusProvider after success', () async {
      var statusReads = 0;
      final fake = _FakeChannel(
        grantOutcome: const LauncherGrantOutcome(ok: true, results: []),
      );
      final c = ProviderContainer(
        overrides: [
          launcherBootstrapChannelProvider.overrideWithValue(fake),
          launcherPrivilegeStatusProvider.overrideWith((_) async {
            statusReads++;
            return const LauncherPrivilegeStatus();
          }),
        ],
      );
      addTearDown(c.dispose);
      // First read primes the provider — counts as 1.
      await c.read(launcherPrivilegeStatusProvider.future);
      expect(statusReads, 1);
      // grantAll must invalidate, forcing a second read.
      await c.read(launcherBootstrapControllerProvider.notifier).grantAll();
      await c.read(launcherPrivilegeStatusProvider.future);
      expect(statusReads, 2);
    });
  });

  group('LauncherBootstrapController.setLauncherModeEnabled', () {
    test('forwards the flag to the channel', () async {
      final fake = _FakeChannel();
      final c = _container(channel: fake);
      await c
          .read(launcherBootstrapControllerProvider.notifier)
          .setLauncherModeEnabled(true);
      expect(fake.lastEnabled, 1);
      await c
          .read(launcherBootstrapControllerProvider.notifier)
          .setLauncherModeEnabled(false);
      expect(fake.lastEnabled, 0);
    });
  });

  group('LauncherBootstrapController.requestDefaultHome', () {
    test('records the outcome and invalidates status', () async {
      final fake = _FakeChannel(
        homeOutcome: const LauncherDefaultHomeOutcome(
          ok: true,
          method: 'role_manager',
        ),
      );
      final c = _container(channel: fake);
      final outcome = await c
          .read(launcherBootstrapControllerProvider.notifier)
          .requestDefaultHome();
      expect(outcome.ok, isTrue);
      expect(outcome.method, 'role_manager');
      expect(
        c.read(launcherBootstrapControllerProvider).lastDefaultHome?.ok,
        isTrue,
      );
    });

    test('translates no_picker_activity reason into typed field', () {
      final out = LauncherDefaultHomeOutcome.fromMap({
        'ok': false,
        'reason': 'no_picker_activity',
        'detail': 'ActivityNotFoundException',
      });
      expect(out.noPickerActivityDetail, 'ActivityNotFoundException');
      expect(out.unreachableReason, isNull);
      expect(out.aliasEnableFailureDetail, isNull);
    });
  });

  group('LauncherGrantOutcome.fromMap', () {
    test('parses the success payload', () {
      final raw = {
        'ok': true,
        'results': [
          {'key': 'readLogs', 'ok': true, 'output': ''},
          {'key': 'mediaContentControl', 'ok': false, 'output': 'denied'},
        ],
      };
      final out = LauncherGrantOutcome.fromMap(raw);
      expect(out.ok, isTrue);
      expect(out.results, hasLength(2));
      expect(out.results.last.ok, isFalse);
      expect(out.results.last.output, 'denied');
    });

    test('translates adb_unreachable into the dedicated field', () {
      final raw = {
        'ok': false,
        'reason': 'adb_unreachable',
        'detail': 'Error: timed out',
      };
      final out = LauncherGrantOutcome.fromMap(raw);
      expect(out.ok, isFalse);
      expect(out.unreachableReason, 'Error: timed out');
      expect(out.results, isEmpty);
    });
  });

  group('LauncherDefaultHomeOutcome.fromMap', () {
    test('separates adb_unreachable from alias_enable_failed', () {
      final adb = LauncherDefaultHomeOutcome.fromMap({
        'ok': false,
        'reason': 'adb_unreachable',
        'detail': 'Error: connect refused',
      });
      expect(adb.unreachableReason, 'Error: connect refused');
      expect(adb.aliasEnableFailureDetail, isNull);

      final alias = LauncherDefaultHomeOutcome.fromMap({
        'ok': false,
        'reason': 'alias_enable_failed',
        'detail': 'unknown component',
      });
      expect(alias.aliasEnableFailureDetail, 'unknown component');
      expect(alias.unreachableReason, isNull);
    });
  });
}
