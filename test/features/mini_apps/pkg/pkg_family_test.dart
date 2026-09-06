/// Tests for [PkgFamily]. The family splits ops across two
/// permissions (`pkg.read` for list/foreground/usage,
/// `pkg.launch` for launch) and exposes its read handlers on a
/// secondary surface. Both invariants are easy to flip
/// accidentally — these tests are the fence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_family.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_native_bridge.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_snapshot.dart';

const _session = AdminSession(
  userId: 'u',
  deviceId: 'VIN',
  appId: 'app',
  certHash: 'cert',
);

class _FakeBridge implements PkgNativeBridge {
  List<PackageSnapshot> nextList = const [];
  ForegroundPackage? nextForeground;
  List<UsageRow> nextUsage = const [];
  LaunchResult nextLaunch = const LaunchResult(ok: true, path: 'intent-launch');
  final List<({String op, Map<String, Object?> args})> calls = [];

  @override
  Future<List<PackageSnapshot>> list({bool includeSystem = false}) async {
    calls.add((op: 'list', args: {'includeSystem': includeSystem}));
    return nextList;
  }

  @override
  Future<ForegroundPackage?> foreground() async {
    calls.add((op: 'foreground', args: const {}));
    return nextForeground;
  }

  @override
  Future<List<UsageRow>> usage({required int windowMs}) async {
    calls.add((op: 'usage', args: {'windowMs': windowMs}));
    return nextUsage;
  }

  @override
  Future<LaunchResult> launch({
    required String packageName,
    int? displayId,
    String? targetRole,
  }) async {
    calls.add((
      op: 'launch',
      args: {'packageName': packageName, 'displayId': displayId},
    ));
    return nextLaunch;
  }

  LaunchResult nextMove = const LaunchResult(ok: true, path: 'move-task');

  @override
  Future<LaunchResult> move({
    required String packageName,
    required int displayId,
  }) async {
    calls.add((
      op: 'move',
      args: {'packageName': packageName, 'displayId': displayId},
    ));
    return nextMove;
  }

  LaunchResult nextLaunchCluster = const LaunchResult(
    ok: true,
    path: 'am-start',
  );

  @override
  Future<LaunchResult> launchCluster({
    required String packageName,
    required int displayId,
  }) async {
    calls.add((
      op: 'launch_cluster',
      args: {'packageName': packageName, 'displayId': displayId},
    ));
    return nextLaunchCluster;
  }

  LaunchResult nextMoveCluster = const LaunchResult(
    ok: true,
    path: 'move-task',
  );

  @override
  Future<LaunchResult> moveCluster({
    required String packageName,
    required int displayId,
  }) async {
    calls.add((
      op: 'move_cluster',
      args: {'packageName': packageName, 'displayId': displayId},
    ));
    return nextMoveCluster;
  }

  LaunchResult nextStop = const LaunchResult(ok: true, path: 'force-stop');

  @override
  Future<LaunchResult> stop({required String packageName}) async {
    calls.add((op: 'stop', args: {'packageName': packageName}));
    return nextStop;
  }

  PkgIconResult nextIcon = const PkgIconResult(ok: true, pngBase64: 'AAAA');

  @override
  Future<PkgIconResult> icon({required String packageName}) async {
    calls.add((op: 'icon', args: {'packageName': packageName}));
    return nextIcon;
  }

  List<RunningTask> nextRunning = const [];

  @override
  Future<List<RunningTask>> running() async {
    calls.add((op: 'running', args: const {}));
    return nextRunning;
  }

  String? topOnDisplayResult;

  @override
  Future<String?> topOnDisplay(int displayId) async {
    calls.add((op: 'topOnDisplay', args: {'displayId': displayId}));
    return topOnDisplayResult;
  }

  @override
  Future<TourMarkerResult> tourMarker({
    required int displayId,
    required int colorArgb,
    String label = '',
  }) async {
    calls.add((
      op: 'tourMarker',
      args: {'displayId': displayId, 'colorArgb': colorArgb, 'label': label},
    ));
    return TourMarkerResult.ok();
  }

  @override
  Future<void> tourFinish() async {
    calls.add((op: 'tourFinish', args: const {}));
  }

  // ── Cluster surface (cluster-pad path; not exercised by these
  //    Pkg-family op tests). Default to inert returns so the
  //    interface is satisfied; tests that assert on this surface
  //    use a dedicated fake.
  @override
  Future<List<String>> clusterPolicyAdded() async => const [];

  @override
  Future<Set<String>> clusterPolicyClassify(List<String> packages) async =>
      const {};

  @override
  Future<List<String>> clusterPolicyAdd(String packageName) async => const [];

  @override
  Future<List<String>> clusterPolicyRemove(String packageName) async =>
      const [];

  @override
  Future<bool> clusterCursorShow(int displayId, int width, int height) async =>
      false;

  @override
  Future<bool> clusterCursorMove(int x, int y) async => false;

  @override
  Future<bool> clusterCursorHide() async => false;

  @override
  Future<bool> clusterClear() async => false;

  @override
  Future<LaunchResult> projectToCluster({
    required String packageName,
    required int displayId,
  }) async {
    calls.add((
      op: 'project_to_cluster',
      args: {'packageName': packageName, 'displayId': displayId},
    ));
    return nextMoveCluster;
  }

  @override
  Future<LaunchResult> projectContentToCluster({
    required String bundleUri,
    required int displayId,
    String route = '/',
    String appId = '',
  }) async {
    calls.add((
      op: 'project_content_to_cluster',
      args: {'bundleUri': bundleUri, 'displayId': displayId, 'route': route},
    ));
    return nextMoveCluster;
  }

  @override
  Future<ClusterProjectionInfo?> clusterProjection() async => null;

  @override
  Future<String?> stopClusterProjection() async => null;
}

BridgeCall _call(String op, [Map<String, Object?> params = const {}]) =>
    BridgeCall(familyId: 'pkg', op: op, params: params, session: _session);

void main() {
  group('PkgFamily', () {
    late _FakeBridge bridge;
    late PkgFamily family;

    setUp(() {
      bridge = _FakeBridge();
      family = PkgFamily(bridge: bridge);
    });

    test('familyId + permission set spans read, launch, launch.cluster', () {
      expect(family.familyId, 'pkg');
      expect(family.permissionIds, {
        'pkg.read',
        'pkg.launch',
        'pkg.launch.cluster',
      });
    });

    test('per-op permission routing splits read vs launch vs cluster', () {
      expect(family.permissionIdFor('list'), 'pkg.read');
      expect(family.permissionIdFor('foreground'), 'pkg.read');
      expect(family.permissionIdFor('usage'), 'pkg.read');
      expect(family.permissionIdFor('launch'), 'pkg.launch');
      expect(family.permissionIdFor('move'), 'pkg.launch');
      // stop reuses pkg.launch — symmetric: if you can launch it,
      // you can take it down. No new permission tier needed.
      expect(family.permissionIdFor('stop'), 'pkg.launch');
      expect(family.permissionIdFor('launch_cluster'), 'pkg.launch.cluster');
      expect(family.permissionIdFor('move_cluster'), 'pkg.launch.cluster');
      // Future ops default to pkg.read so a forgotten registration
      // doesn't accidentally over-grant.
      expect(family.permissionIdFor('hypothetical-future-op'), 'pkg.read');
    });

    test('secondaryAllowed is true for reads, false for every write', () {
      expect(family.secondaryAllowed, isTrue);
      expect(family.secondaryAllowedFor('list'), isTrue);
      expect(family.secondaryAllowedFor('foreground'), isTrue);
      expect(family.secondaryAllowedFor('usage'), isTrue);
      expect(family.secondaryAllowedFor('launch'), isFalse);
      expect(family.secondaryAllowedFor('move'), isFalse);
      expect(family.secondaryAllowedFor('stop'), isFalse);
      expect(family.secondaryAllowedFor('launch_cluster'), isFalse);
      expect(family.secondaryAllowedFor('move_cluster'), isFalse);
    });

    test('list passes through includeSystem and shapes the response', () async {
      bridge.nextList = const [
        PackageSnapshot(
          packageName: 'com.byd.maps',
          label: 'Maps',
          versionName: '5.0',
          versionCode: 100,
          isSystem: false,
        ),
      ];
      final r = await family.handlers['list']!.execute(_call('list'));
      final packages = r['packages']! as List;
      expect(packages, hasLength(1));
      expect((packages.first as Map)['packageName'], 'com.byd.maps');
      expect(bridge.calls.last.args['includeSystem'], false);

      await family.handlers['list']!.execute(
        _call('list', {'includeSystem': true}),
      );
      expect(bridge.calls.last.args['includeSystem'], true);
    });

    test('foreground returns the canonical no-info shape on null', () async {
      bridge.nextForeground = null;
      final r = await family.handlers['foreground']!.execute(
        _call('foreground'),
      );
      // Mini-app reads `packageName == null` as "host can't determine"
      // — don't throw, don't return an empty map.
      expect(r['packageName'], isNull);
    });

    test('foreground forwards the bridge result when present', () async {
      bridge.nextForeground = const ForegroundPackage(
        packageName: 'com.example.amapservice',
        activityClass: 'com.example.amapservice/.MapActivity',
        atMillis: 1000,
      );
      final r = await family.handlers['foreground']!.execute(
        _call('foreground'),
      );
      expect(r['packageName'], 'com.example.amapservice');
      expect(r['activityClass'], 'com.example.amapservice/.MapActivity');
    });

    test('usage validates windowMs and rolls up rows', () async {
      bridge.nextUsage = const [
        UsageRow(
          packageName: 'com.byd.maps',
          totalTimeInForegroundMs: 60000,
          lastTimeUsedMs: 999,
        ),
      ];
      final r = await family.handlers['usage']!.execute(
        _call('usage', {'windowMs': 60_000}),
      );
      expect((r['rows'] as List).length, 1);
      expect(r['windowMs'], 60_000);
      expect(bridge.calls.last.args['windowMs'], 60_000);
    });

    test('launch rejects invalid package names', () async {
      // No dot — not a valid Android package name.
      await expectLater(
        () => family.handlers['launch']!.execute(
          _call('launch', {'packageName': 'invalid'}),
        ),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'pkg_invalid'),
        ),
      );
      // Empty string.
      await expectLater(
        () => family.handlers['launch']!.execute(
          _call('launch', {'packageName': ''}),
        ),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'pkg_invalid'),
        ),
      );
      // No call should have made it to the bridge.
      expect(bridge.calls.where((c) => c.op == 'launch'), isEmpty);
    });

    test('launch forwards a valid package name + displayId', () async {
      bridge.nextLaunch = const LaunchResult(ok: true, path: 'am-start');
      final r = await family.handlers['launch']!.execute(
        _call('launch', {'packageName': 'com.byd.maps', 'displayId': 4}),
      );
      expect(r['ok'], true);
      expect(r['path'], 'am-start');
      final args = bridge.calls.last.args;
      expect(args['packageName'], 'com.byd.maps');
      expect(args['displayId'], 4);
    });

    test('launch wraps native exceptions as pkg_launch_failed', () async {
      bridge = _FakeBridge();
      family = PkgFamily(bridge: _ThrowingBridge());
      await expectLater(
        () => family.handlers['launch']!.execute(
          _call('launch', {'packageName': 'com.byd.maps'}),
        ),
        throwsA(
          isA<BridgeOpError>().having(
            (e) => e.code,
            'code',
            'pkg_launch_failed',
          ),
        ),
      );
    });

    test(
      'launch_cluster routes to bridge.launchCluster, not bridge.launch',
      () async {
        bridge.nextLaunchCluster = const LaunchResult(
          ok: true,
          path: 'am-start',
        );
        final r = await family.handlers['launch_cluster']!.execute(
          _call('launch_cluster', {
            'packageName': 'com.byd.maps',
            'displayId': 4,
          }),
        );
        expect(r['ok'], true);
        expect(r['path'], 'am-start');
        // The cluster op MUST hit launch_cluster on the bridge — not
        // launch — so the native side gets the expectCluster=true
        // signal and enforces the role check.
        expect(bridge.calls.last.op, 'launch_cluster');
        expect(bridge.calls.last.args['displayId'], 4);
      },
    );

    test(
      'launch_cluster requires displayId (no default-display fallback)',
      () async {
        // Same regex check; missing displayId fails the param schema
        // before execute runs (validated by the gate). Here we only
        // assert the schema declares displayId as required.
        final schema = family.handlers['launch_cluster']!.paramSchema;
        expect(schema.containsKey('displayId'), isTrue);
        expect(schema.containsKey('packageName'), isTrue);
      },
    );

    test(
      'launch_cluster wraps native errors as pkg_launch_cluster_failed',
      () async {
        family = PkgFamily(bridge: _ThrowingBridge());
        await expectLater(
          () => family.handlers['launch_cluster']!.execute(
            _call('launch_cluster', {
              'packageName': 'com.byd.maps',
              'displayId': 4,
            }),
          ),
          throwsA(
            isA<BridgeOpError>().having(
              (e) => e.code,
              'code',
              'pkg_launch_cluster_failed',
            ),
          ),
        );
      },
    );

    test('move_cluster routes to bridge.moveCluster', () async {
      bridge.nextMoveCluster = const LaunchResult(ok: true, path: 'move-task');
      final r = await family.handlers['move_cluster']!.execute(
        _call('move_cluster', {'packageName': 'com.byd.maps', 'displayId': 4}),
      );
      expect(r['ok'], true);
      expect(r['path'], 'move-task');
      expect(bridge.calls.last.op, 'move_cluster');
    });

    test(
      'move_cluster wraps native errors as pkg_move_cluster_failed',
      () async {
        family = PkgFamily(bridge: _ThrowingBridge());
        await expectLater(
          () => family.handlers['move_cluster']!.execute(
            _call('move_cluster', {
              'packageName': 'com.byd.maps',
              'displayId': 4,
            }),
          ),
          throwsA(
            isA<BridgeOpError>().having(
              (e) => e.code,
              'code',
              'pkg_move_cluster_failed',
            ),
          ),
        );
      },
    );

    test('stop forwards packageName to bridge.stop', () async {
      bridge.nextStop = const LaunchResult(ok: true, path: 'force-stop');
      final r = await family.handlers['stop']!.execute(
        _call('stop', {'packageName': 'com.byd.maps'}),
      );
      expect(r['ok'], true);
      expect(r['path'], 'force-stop');
      expect(bridge.calls.last.op, 'stop');
      expect(bridge.calls.last.args['packageName'], 'com.byd.maps');
    });

    test('stop wraps native errors as pkg_stop_failed', () async {
      family = PkgFamily(bridge: _ThrowingBridge());
      await expectLater(
        () => family.handlers['stop']!.execute(
          _call('stop', {'packageName': 'com.byd.maps'}),
        ),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'pkg_stop_failed'),
        ),
      );
    });
  });
}

class _ThrowingBridge implements PkgNativeBridge {
  @override
  Future<List<PackageSnapshot>> list({bool includeSystem = false}) async => [];

  @override
  Future<ForegroundPackage?> foreground() async => null;

  @override
  Future<List<UsageRow>> usage({required int windowMs}) async => [];

  @override
  Future<LaunchResult> launch({
    required String packageName,
    int? displayId,
    String? targetRole,
  }) async {
    throw Exception('boom');
  }

  @override
  Future<LaunchResult> move({
    required String packageName,
    required int displayId,
  }) async {
    throw Exception('boom');
  }

  @override
  Future<LaunchResult> launchCluster({
    required String packageName,
    required int displayId,
  }) async {
    throw Exception('boom');
  }

  @override
  Future<LaunchResult> moveCluster({
    required String packageName,
    required int displayId,
  }) async {
    throw Exception('boom');
  }

  @override
  Future<LaunchResult> stop({required String packageName}) async {
    throw Exception('boom');
  }

  @override
  Future<PkgIconResult> icon({required String packageName}) async {
    throw Exception('boom');
  }

  @override
  Future<List<RunningTask>> running() async {
    throw Exception('boom');
  }

  @override
  Future<String?> topOnDisplay(int displayId) async {
    throw Exception('boom');
  }

  @override
  Future<TourMarkerResult> tourMarker({
    required int displayId,
    required int colorArgb,
    String label = '',
  }) async {
    throw Exception('boom');
  }

  @override
  Future<void> tourFinish() async {
    throw Exception('boom');
  }

  // ── Cluster surface — also throws, matching the "every op fails"
  //    contract this fake encodes.
  @override
  Future<List<String>> clusterPolicyAdded() async => throw Exception('boom');

  @override
  Future<Set<String>> clusterPolicyClassify(List<String> packages) async =>
      throw Exception('boom');

  @override
  Future<List<String>> clusterPolicyAdd(String packageName) async =>
      throw Exception('boom');

  @override
  Future<List<String>> clusterPolicyRemove(String packageName) async =>
      throw Exception('boom');

  @override
  Future<bool> clusterCursorShow(int displayId, int width, int height) async =>
      throw Exception('boom');

  @override
  Future<bool> clusterCursorMove(int x, int y) async => throw Exception('boom');

  @override
  Future<bool> clusterCursorHide() async => throw Exception('boom');

  @override
  Future<bool> clusterClear() async => throw Exception('boom');

  @override
  Future<LaunchResult> projectToCluster({
    required String packageName,
    required int displayId,
  }) async => throw Exception('boom');

  @override
  Future<LaunchResult> projectContentToCluster({
    required String bundleUri,
    required int displayId,
    String route = '/',
    String appId = '',
  }) async => throw Exception('boom');

  @override
  Future<ClusterProjectionInfo?> clusterProjection() async =>
      throw Exception('boom');

  @override
  Future<String?> stopClusterProjection() async => throw Exception('boom');
}
