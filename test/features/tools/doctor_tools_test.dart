import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/home/state/installed_apps_provider.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_native_bridge.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_snapshot.dart';
import 'package:ilink/features/tools/domain/quick_fix_action.dart';
import 'package:ilink/features/tools/presentation/sheets/doctor_sheet.dart';
import 'package:ilink/features/tools/registry/quick_fix_registry.dart';
import 'package:ilink/features/tools/state/quick_fix_controller.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/sdk/car/providers.dart' show daemonReadyProvider;

QuickFixAction _byId(String id) =>
    kQuickFixActions.firstWhere((a) => a.id == id);

void main() {
  group('kQuickFixActions registry', () {
    test('exposes the three actions in order with the stable ids', () {
      expect(kQuickFixActions.map((a) => a.id).toList(), [
        kCloseAppsActionId,
        kClearClusterActionId,
        kWakeDaemonActionId,
      ]);
    });

    test('ids are unique; label + why keys are non-empty', () {
      final ids = kQuickFixActions.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final a in kQuickFixActions) {
        expect(a.labelKey, isNotEmpty);
        expect(a.whyKey, isNotEmpty);
      }
    });
  });

  group('QuickFixController', () {
    QuickFixAction fake(String id, Future<QuickFixResult> Function() body) =>
        QuickFixAction(
          id: id,
          icon: Icons.build,
          labelKey: 'l',
          whyKey: 'w',
          run: (_) => body(),
        );

    test('idle → running → ok(count)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(quickFixControllerProvider.notifier);
      final gate = Completer<QuickFixResult>();
      final fut = ctrl.run(fake('a', () => gate.future));
      expect(ctrl.stateFor('a').status, QuickFixStatus.running);
      gate.complete(const QuickFixResult.ok(3));
      await fut;
      expect(ctrl.stateFor('a').status, QuickFixStatus.ok);
      expect(ctrl.stateFor('a').count, 3);
    });

    test('a thrown error resolves to failed (never escapes)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(quickFixControllerProvider.notifier);
      await ctrl.run(fake('b', () async => throw Exception('boom')));
      expect(ctrl.stateFor('b').status, QuickFixStatus.failed);
    });

    test('re-entrant run while one is in flight is ignored', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(quickFixControllerProvider.notifier);
      var calls = 0;
      final gate = Completer<QuickFixResult>();
      final a = fake('c', () {
        calls++;
        return gate.future;
      });
      final first = ctrl.run(a);
      await ctrl.run(a); // still running → no-op
      expect(calls, 1);
      gate.complete(const QuickFixResult.ok());
      await first;
    });
  });

  group('closeOtherApps', () {
    test('force-stops only running USER apps — never host or system', () async {
      final bridge = _FakePkgBridge()
        ..runningTasks = [
          _task('com.user.maps'),
          _task('com.i99dev.ilink'), // host — must be skipped
          _task('com.android.systemui'), // system (absent from list) — skip
          _task('com.user.music'),
          _task('com.user.maps'), // duplicate task → dedup
        ];
      final container = ProviderContainer(
        overrides: [
          pkgBridgeProvider.overrideWithValue(bridge),
          installedAppsProvider.overrideWith(
            (ref) async => [_snap('com.user.maps'), _snap('com.user.music')],
          ),
        ],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(quickFixControllerProvider.notifier);
      await ctrl.run(_byId(kCloseAppsActionId));

      expect(bridge.stopped, {'com.user.maps', 'com.user.music'});
      expect(bridge.stopped, isNot(contains('com.i99dev.ilink')));
      expect(bridge.stopped, isNot(contains('com.android.systemui')));
      final st = ctrl.stateFor(kCloseAppsActionId);
      expect(st.status, QuickFixStatus.ok);
      expect(st.count, 2);
    });

    test('no user apps running → ok(0), nothing stopped', () async {
      final bridge = _FakePkgBridge()
        ..runningTasks = [
          _task('com.i99dev.ilink'),
          _task('com.android.systemui'),
        ];
      final container = ProviderContainer(
        overrides: [
          pkgBridgeProvider.overrideWithValue(bridge),
          installedAppsProvider.overrideWith(
            (ref) async => [_snap('com.user.maps')],
          ),
        ],
      );
      addTearDown(container.dispose);
      final ctrl = container.read(quickFixControllerProvider.notifier);
      await ctrl.run(_byId(kCloseAppsActionId));
      expect(bridge.stopped, isEmpty);
      expect(ctrl.stateFor(kCloseAppsActionId).count, 0);
    });
  });

  group('clearCluster', () {
    test('clusterClear true → ok, false → failed', () async {
      for (final ok in [true, false]) {
        final bridge = _FakePkgBridge()..clusterClearResult = ok;
        final c = ProviderContainer(
          overrides: [pkgBridgeProvider.overrideWithValue(bridge)],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(quickFixControllerProvider.notifier);
        await ctrl.run(_byId(kClearClusterActionId));
        expect(
          ctrl.stateFor(kClearClusterActionId).status,
          ok ? QuickFixStatus.ok : QuickFixStatus.failed,
        );
      }
    });
  });

  group('DoctorSheet', () {
    testWidgets('renders all three actions with label, why, and tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          // Override the daemon-readiness stream with a finite one — the
          // real provider is an infinite 2s-poll loop that would leave a
          // pending timer at teardown. DoctorSheet now reads it to tint
          // the Wake-car-service icon.
          overrides: [
            daemonReadyProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: const MaterialApp(
            localizationsDelegates: [
              S.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: S.supportedLocales,
            locale: Locale('en'),
            home: Scaffold(body: DoctorSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Labels.
      expect(find.text('Close other apps'), findsOneWidget);
      expect(find.text('Clear cluster'), findsOneWidget);
      expect(find.text('Wake car service'), findsOneWidget);
      // "Why" subtitle visible while idle.
      expect(find.textContaining('Force-stops other apps'), findsOneWidget);
      // One long-press tooltip per action.
      expect(find.byType(Tooltip), findsNWidgets(kQuickFixActions.length));
    });
  });
}

RunningTask _task(String pkg) => RunningTask(
  taskId: pkg.hashCode,
  rootTaskId: pkg.hashCode,
  displayId: 0,
  packageName: pkg,
  isForeground: false,
);

PackageSnapshot _snap(String pkg) => PackageSnapshot(
  packageName: pkg,
  label: pkg,
  versionName: '1',
  versionCode: 1,
  isSystem: false,
);

/// Minimal fake — only `running` / `stop` / `clusterClear` are exercised
/// by the Doctor actions; the rest of the broad [PkgNativeBridge] surface
/// throws so accidental use surfaces loudly.
class _FakePkgBridge implements PkgNativeBridge {
  List<RunningTask> runningTasks = const [];
  final Set<String> stopped = {};
  bool clusterClearResult = true;

  @override
  Future<List<RunningTask>> running() async => runningTasks;

  @override
  Future<LaunchResult> stop({required String packageName}) async {
    stopped.add(packageName);
    return const LaunchResult(ok: true, path: 'am-force-stop');
  }

  @override
  Future<bool> clusterClear() async => clusterClearResult;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
