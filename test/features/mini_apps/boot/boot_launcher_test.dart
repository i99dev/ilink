/// Tests for [BootLauncher].
///
/// Covers the four behavioural invariants:
///   * No-op when neither bootEpoch nor receiver flag indicate a
///     fresh boot.
///   * No-op (but mark clean) when the store has no rows for the
///     active session.
///   * Dedupe by `(packageName, displayId)` across multiple
///     mini-apps' rows.
///   * `displayId == -1` translates to `null` at the pkg.launch
///     boundary (host's "default display" sentinel).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/mini_apps/lifecycle/boot_launcher.dart';
import 'package:ilink/features/mini_apps/lifecycle/boot_native_bridge.dart';
import 'package:ilink/features/mini_apps/lifecycle/boot_store.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_native_bridge.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeBootBridge implements BootNativeBridge {
  _FakeBootBridge(this.state);
  BootState state;
  int clearedTimes = 0;

  @override
  Future<BootState> bootState() async => state;

  @override
  Future<void> clearPending() async {
    clearedTimes++;
    state = BootState(bootEpochMs: state.bootEpochMs, pendingAtMs: 0);
  }
}

class _FakePkgBridge implements PkgNativeBridge {
  final List<({String packageName, int? displayId})> launches = [];
  bool nextOk = true;

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
    launches.add((packageName: packageName, displayId: displayId));
    return LaunchResult(
      ok: nextOk,
      path: displayId == null ? 'intent-launch' : 'am-start',
    );
  }

  @override
  Future<LaunchResult> move({
    required String packageName,
    required int displayId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<LaunchResult> launchCluster({
    required String packageName,
    required int displayId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<LaunchResult> moveCluster({
    required String packageName,
    required int displayId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<LaunchResult> stop({required String packageName}) async {
    throw UnimplementedError();
  }

  @override
  Future<PkgIconResult> icon({required String packageName}) async {
    throw UnimplementedError();
  }

  @override
  Future<TourMarkerResult> tourMarker({
    required int displayId,
    required int colorArgb,
    String label = '',
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> tourFinish() async {}

  @override
  Future<List<RunningTask>> running() async => const [];

  @override
  Future<String?> topOnDisplay(int displayId) async => null;

  // ── Cluster surface (not exercised by the boot-launcher path) ──
  // The boot launcher only uses `launch`. The cluster-input + policy
  // ops are part of the interface but unreachable here; failing fast
  // surfaces accidental use without coupling these tests to that
  // subsystem.
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
  }) async => throw UnimplementedError();

  @override
  Future<LaunchResult> projectContentToCluster({
    required String bundleUri,
    required int displayId,
    String route = '/',
    String appId = '',
  }) async => throw UnimplementedError();

  @override
  Future<ClusterProjectionInfo?> clusterProjection() async => null;

  @override
  Future<String?> stopClusterProjection() async => null;
}

void main() {
  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  Future<
    ({
      BootStore store,
      BootLauncher launcher,
      _FakeBootBridge boot,
      _FakePkgBridge pkg,
    })
  >
  buildFixture({required int bootEpochMs, required int pendingAtMs}) async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final store = BootStore(db);
    final boot = _FakeBootBridge(
      BootState(bootEpochMs: bootEpochMs, pendingAtMs: pendingAtMs),
    );
    final pkg = _FakePkgBridge();
    final launcher = BootLauncher(
      store: store,
      pkgBridge: pkg,
      bootBridge: boot,
    );
    return (store: store, launcher: launcher, boot: boot, pkg: pkg);
  }

  group('runIfFreshBoot — no-op paths', () {
    test(
      'returns empty when bootEpoch matches stored AND no pending',
      () async {
        // Pre-stamp a "we already replayed for this boot" record.
        SharedPreferences.setMockInitialValues({
          'ilink.boot.last_replayed_boot_epoch_ms': 100000,
        });
        final f = await buildFixture(bootEpochMs: 100000, pendingAtMs: 0);
        final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
        expect(r, isEmpty);
        expect(f.pkg.launches, isEmpty);
        // No clean-up either — nothing happened.
        expect(f.boot.clearedTimes, 0);
      },
    );

    test('returns empty (and marks clean) when no rows for session', () async {
      final f = await buildFixture(bootEpochMs: 100000, pendingAtMs: 0);
      final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
      expect(r, isEmpty);
      expect(f.pkg.launches, isEmpty);
      // Marked clean so we don't keep reading the store every host
      // launch within the same boot.
      expect(f.boot.clearedTimes, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('ilink.boot.last_replayed_boot_epoch_ms'), 100000);
    });
  });

  group('runIfFreshBoot — fresh boot triggers', () {
    test('bootEpoch differs from stored → fires', () async {
      SharedPreferences.setMockInitialValues({
        'ilink.boot.last_replayed_boot_epoch_ms': 100000,
      });
      final f = await buildFixture(bootEpochMs: 200000, pendingAtMs: 0);
      await f.store.set(
        userId: 'u',
        deviceId: 'VIN',
        appId: 'pkg-launcher',
        packageName: 'com.byd.maps',
        displayId: 5,
      );
      final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
      expect(r, hasLength(1));
      expect(r.first.ok, true);
      expect(f.pkg.launches.single.packageName, 'com.byd.maps');
      expect(f.pkg.launches.single.displayId, 5);
    });

    test('receiver pending flag triggers even if bootEpoch matches', () async {
      // Same boot, but receiver staged a fresh "BOOT_COMPLETED" — fire.
      SharedPreferences.setMockInitialValues({
        'ilink.boot.last_replayed_boot_epoch_ms': 100000,
      });
      final f = await buildFixture(bootEpochMs: 100000, pendingAtMs: 555);
      await f.store.set(
        userId: 'u',
        deviceId: 'VIN',
        appId: 'pkg-launcher',
        packageName: 'com.byd.music',
        displayId: -1,
      );
      final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
      expect(r, hasLength(1));
      expect(r.first.ok, true);
      // displayId == -1 → null at the pkg.launch boundary.
      expect(f.pkg.launches.single.displayId, isNull);
      expect(f.boot.clearedTimes, 1);
    });
  });

  group('runIfFreshBoot — dedupe', () {
    test(
      'two mini-apps pinning same (package, display) → one launch',
      () async {
        final f = await buildFixture(bootEpochMs: 200000, pendingAtMs: 0);
        // App A and App B both pin Music to display 5. The launcher
        // should fire one launch, not two.
        await f.store.set(
          userId: 'u',
          deviceId: 'VIN',
          appId: 'app-a',
          packageName: 'com.byd.music',
          displayId: 5,
        );
        await f.store.set(
          userId: 'u',
          deviceId: 'VIN',
          appId: 'app-b',
          packageName: 'com.byd.music',
          displayId: 5,
        );
        // App A also pins Maps to display 4 — distinct row, should fire.
        await f.store.set(
          userId: 'u',
          deviceId: 'VIN',
          appId: 'app-a',
          packageName: 'com.byd.maps',
          displayId: 4,
        );

        final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
        expect(r, hasLength(2));
        final pkgs = f.pkg.launches.map((l) => l.packageName).toSet();
        expect(pkgs, {'com.byd.music', 'com.byd.maps'});
      },
    );

    test(
      'same package on different displays via different mini-apps → both fire',
      () async {
        final f = await buildFixture(bootEpochMs: 200000, pendingAtMs: 0);
        // Edge case: two distinct mini-apps each pin the same package
        // to a different display. The store's PK is
        // (user, deviceId, app, package) so per-app rows are independent;
        // dedupe by (package, displayId) lets both fire because the
        // tuples differ.
        await f.store.set(
          userId: 'u',
          deviceId: 'VIN',
          appId: 'app-a',
          packageName: 'com.byd.music',
          displayId: 4,
        );
        await f.store.set(
          userId: 'u',
          deviceId: 'VIN',
          appId: 'app-b',
          packageName: 'com.byd.music',
          displayId: 5,
        );
        final r = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
        expect(r, hasLength(2));
      },
    );
  });

  group('runIfFreshBoot — never replays for the same boot twice', () {
    test('second call within the same bootEpoch is a no-op', () async {
      final f = await buildFixture(bootEpochMs: 200000, pendingAtMs: 0);
      await f.store.set(
        userId: 'u',
        deviceId: 'VIN',
        appId: 'app-a',
        packageName: 'com.byd.music',
        displayId: 5,
      );
      // First call — fires.
      final r1 = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
      expect(r1, hasLength(1));
      // Second call — same bootEpoch, pending was cleared by the
      // first call, so no replay even though rows still exist.
      final r2 = await f.launcher.runIfFreshBoot(userId: 'u', deviceId: 'VIN');
      expect(r2, isEmpty);
      expect(f.pkg.launches, hasLength(1));
    });
  });
}
