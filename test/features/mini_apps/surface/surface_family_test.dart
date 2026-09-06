/// Tests for [SurfaceFamily].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:ilink/features/mini_apps/runtime/surface_family.dart';
import 'package:ilink/features/mini_apps/runtime/surface_native_bridge.dart';
import 'package:ilink/features/mini_apps/runtime/surface_snapshot.dart';

class _FakeBridge implements SurfaceNativeBridge {
  _FakeBridge({this.failOnCreate = false});
  final bool failOnCreate;
  final List<SurfaceSnapshot> _snapshots = [];
  String? lastNavigatedTo;
  String? lastCreatedAppId;
  String? lastCreatedBundleUri;

  @override
  Future<SurfaceCreateResult> create({
    required int displayId,
    required String appId,
    required String bundleUri,
    String? route,
  }) async {
    if (failOnCreate) throw Exception('XDJA Presentation denied');
    lastCreatedAppId = appId;
    lastCreatedBundleUri = bundleUri;
    final id = 'sfc_${displayId}_${_snapshots.length}';
    final r = SurfaceCreateResult(
      surfaceId: id,
      path: 'presentation',
      displayId: displayId,
      route: route ?? '/',
    );
    _snapshots.add(
      SurfaceSnapshot(
        surfaceId: id,
        displayId: displayId,
        path: 'presentation',
        route: route ?? '/',
      ),
    );
    return r;
  }

  @override
  Future<void> navigate({required String surfaceId, String? route}) async {
    lastNavigatedTo = '$surfaceId→$route';
  }

  @override
  Future<void> destroy({required String surfaceId}) async {
    _snapshots.removeWhere((s) => s.surfaceId == surfaceId);
  }

  @override
  Future<List<SurfaceSnapshot>> list() async => List.of(_snapshots);
}

SurfaceFamily _famWithFakeBundle({
  SurfaceNativeBridge? bridge,
  String? bundleUri = 'file:///data/local/tmp/app-a/index.html',
}) {
  return SurfaceFamily(
    bridge: bridge ?? _FakeBridge(),
    bundleUriResolver: (_) async => bundleUri,
  );
}

const _session = AdminSession(
  userId: 'u',
  deviceId: 'V',
  appId: 'a',
  certHash: 'c',
);

void main() {
  group('SurfaceFamily', () {
    test('familyId / permissionIds / secondaryAllowed', () {
      final fam = SurfaceFamily(bridge: _FakeBridge());
      expect(fam.familyId, 'surface');
      expect(fam.permissionIds, {'surface.write'});
      expect(
        fam.secondaryAllowed,
        isFalse,
        reason:
            'recursive surface creation must be blocked on a secondary surface',
      );
    });

    test('create + list + destroy round-trip', () async {
      final bridge = _FakeBridge();
      final fam = _famWithFakeBundle(bridge: bridge);

      final create = await fam.handlers['create']!.execute(
        const BridgeCall(
          familyId: 'surface',
          op: 'create',
          params: {'displayId': 4, 'route': '/cluster'},
          session: _session,
        ),
      );
      expect(create['displayId'], 4);
      expect(create['path'], 'presentation');
      final id = create['surfaceId'] as String;
      expect(id, startsWith('sfc_'));

      final list = await fam.handlers['list']!.execute(
        const BridgeCall(
          familyId: 'surface',
          op: 'list',
          params: {},
          session: _session,
        ),
      );
      expect((list['surfaces'] as List), hasLength(1));

      await fam.handlers['destroy']!.execute(
        BridgeCall(
          familyId: 'surface',
          op: 'destroy',
          params: {'surfaceId': id},
          session: _session,
        ),
      );
      final list2 = await fam.handlers['list']!.execute(
        const BridgeCall(
          familyId: 'surface',
          op: 'list',
          params: {},
          session: _session,
        ),
      );
      expect((list2['surfaces'] as List), isEmpty);
    });

    test('create surfaces native exception as surface_denied', () async {
      final bridge = _FakeBridge(failOnCreate: true);
      final fam = _famWithFakeBundle(bridge: bridge);
      try {
        await fam.handlers['create']!.execute(
          const BridgeCall(
            familyId: 'surface',
            op: 'create',
            params: {'displayId': 4, 'route': '/'},
            session: _session,
          ),
        );
        fail('expected BridgeOpError');
      } on BridgeOpError catch (e) {
        expect(e.code, 'surface_denied');
        expect(e.message, contains('XDJA'));
      }
    });

    test('navigate hits the bridge with the right surfaceId + route', () async {
      final bridge = _FakeBridge();
      final fam = _famWithFakeBundle(bridge: bridge);
      // Bridge accepts any sfc_<hex> id, so seed one through create:
      final r = await fam.handlers['create']!.execute(
        const BridgeCall(
          familyId: 'surface',
          op: 'create',
          params: {'displayId': 4, 'route': '/'},
          session: _session,
        ),
      );
      final id = r['surfaceId'] as String;
      // Use a UUID-ish id for the navigate regex; the fake bridge's
      // create returned `sfc_4_0`, which doesn't match the schema.
      // Use a synthetic id matching the regex instead:
      const syntheticId = 'sfc_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      await fam.handlers['navigate']!.execute(
        const BridgeCall(
          familyId: 'surface',
          op: 'navigate',
          params: {'surfaceId': syntheticId, 'route': '/cluster/widget'},
          session: _session,
        ),
      );
      expect(bridge.lastNavigatedTo, '$syntheticId→/cluster/widget');
      // Suppress unused-id warning:
      expect(id, isNotEmpty);
    });

    test(
      'create resolves the bundle URI and forwards it to the bridge',
      () async {
        final bridge = _FakeBridge();
        const bundlePath = 'file:///data/local/tmp/cluster-app/index.html';
        final fam = SurfaceFamily(
          bridge: bridge,
          bundleUriResolver: (appId) async {
            expect(appId, 'a');
            return bundlePath;
          },
        );
        await fam.handlers['create']!.execute(
          const BridgeCall(
            familyId: 'surface',
            op: 'create',
            params: {'displayId': 4, 'route': '/'},
            session: _session,
          ),
        );
        expect(bridge.lastCreatedAppId, 'a');
        expect(bridge.lastCreatedBundleUri, bundlePath);
      },
    );

    test('create fails surface_denied when bundle is not installed', () async {
      final bridge = _FakeBridge();
      final fam = SurfaceFamily(
        bridge: bridge,
        bundleUriResolver: (_) async => null,
      );
      try {
        await fam.handlers['create']!.execute(
          const BridgeCall(
            familyId: 'surface',
            op: 'create',
            params: {'displayId': 4, 'route': '/'},
            session: _session,
          ),
        );
        fail('expected BridgeOpError');
      } on BridgeOpError catch (e) {
        expect(e.code, 'surface_denied');
        expect(e.message, contains('not installed'));
      }
      // Native bridge was NOT called — fail-closed before any IPC.
      expect(bridge.lastCreatedBundleUri, isNull);
    });
  });
}
