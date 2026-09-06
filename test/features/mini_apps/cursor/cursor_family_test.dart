/// Tests for [CursorFamily]. Focus on the lifecycle invariants:
///   * attach / detach round-trip.
///   * move is `HandlerCadence.hot` so the gate's hot-path bypass
///     short-circuits per-call gating.
///   * style swap forwards through.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:ilink/features/mini_apps/runtime/cursor_family.dart';
import 'package:ilink/features/mini_apps/runtime/cursor_native_bridge.dart';

const _session = AdminSession(
  userId: 'u',
  deviceId: 'VIN',
  appId: 'cluster-remote',
  certHash: 'cert',
);

class _FakeBridge implements CursorNativeBridge {
  final List<({String op, Map<String, Object?> args})> calls = [];
  bool nextAttachOk = true;

  @override
  Future<bool> attach({
    required int targetDisplayId,
    required String style,
  }) async {
    calls.add((
      op: 'attach',
      args: <String, Object?>{
        'targetDisplayId': targetDisplayId,
        'style': style,
      },
    ));
    return nextAttachOk;
  }

  @override
  Future<void> detach() async {
    calls.add((op: 'detach', args: const <String, Object?>{}));
  }

  @override
  Future<void> move({required double x, required double y}) async {
    calls.add((op: 'move', args: <String, Object?>{'x': x, 'y': y}));
  }

  @override
  Future<void> style(String style) async {
    calls.add((op: 'style', args: <String, Object?>{'style': style}));
  }
}

void main() {
  group('CursorFamily', () {
    late _FakeBridge bridge;
    late CursorFamily family;

    setUp(() {
      bridge = _FakeBridge();
      family = CursorFamily(bridge: bridge);
    });

    test('familyId + permissionIds + privileged posture', () {
      expect(family.familyId, 'cursor');
      expect(family.permissionIds, {'cursor.write'});
      expect(family.secondaryAllowed, isFalse);
    });

    test('move handler is HandlerCadence.hot for 60Hz drag bypass', () {
      expect(family.handlers['move']!.cadence, HandlerCadence.hot);
      // attach / detach / style stay standard so the gate runs at the
      // session boundaries.
      expect(family.handlers['attach']!.cadence, HandlerCadence.standard);
      expect(family.handlers['detach']!.cadence, HandlerCadence.standard);
      expect(family.handlers['style']!.cadence, HandlerCadence.standard);
    });

    test('attach forwards style + targetDisplayId, returns ok', () async {
      final r = await family.handlers['attach']!.execute(
        const BridgeCall(
          familyId: 'cursor',
          op: 'attach',
          params: {'targetDisplayId': 4, 'style': 'glow'},
          session: _session,
        ),
      );
      expect(r['ok'], isTrue);
      expect(bridge.calls.first.op, 'attach');
      expect(bridge.calls.first.args['targetDisplayId'], 4);
      expect(bridge.calls.first.args['style'], 'glow');
    });

    test('attach returns ok=false when bridge refuses', () async {
      bridge.nextAttachOk = false;
      final r = await family.handlers['attach']!.execute(
        const BridgeCall(
          familyId: 'cursor',
          op: 'attach',
          params: {'targetDisplayId': 4, 'style': 'dot'},
          session: _session,
        ),
      );
      expect(r['ok'], isFalse);
    });

    test('move forwards coords as doubles', () async {
      await family.handlers['move']!.execute(
        const BridgeCall(
          familyId: 'cursor',
          op: 'move',
          params: {'x': 960, 'y': 360},
          session: _session,
        ),
      );
      expect(bridge.calls.first.op, 'move');
      expect(bridge.calls.first.args['x'], 960.0);
      expect(bridge.calls.first.args['y'], 360.0);
    });

    test('style swap forwards new style', () async {
      await family.handlers['style']!.execute(
        const BridgeCall(
          familyId: 'cursor',
          op: 'style',
          params: {'style': 'ring'},
          session: _session,
        ),
      );
      expect(bridge.calls.first.op, 'style');
      expect(bridge.calls.first.args['style'], 'ring');
    });

    test('detach takes no params', () async {
      await family.handlers['detach']!.execute(
        const BridgeCall(
          familyId: 'cursor',
          op: 'detach',
          params: {},
          session: _session,
        ),
      );
      expect(bridge.calls.first.op, 'detach');
      expect(bridge.calls.first.args, isEmpty);
    });
  });
}
