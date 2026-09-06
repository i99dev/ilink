/// Tests for [GestureFamily]. Param-schema validation is exercised by
/// the family-executor's gate, so these tests focus on what's
/// gesture-specific:
///   * Each handler routes to the matching native-bridge method with
///     the right shape.
///   * `requiresStepUp` is true on every handler — synthetic input on
///     the cluster is the most dangerous primitive.
///   * Coordinates are forwarded as doubles even though the param
///     schema accepts ints (the bridge spec is double-precision).
///   * `dispatched=false` results pass through verbatim.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:ilink/features/mini_apps/runtime/gesture_family.dart';
import 'package:ilink/features/mini_apps/runtime/gesture_native_bridge.dart';

const _session = AdminSession(
  userId: 'u',
  deviceId: 'VIN',
  appId: 'cluster-remote',
  certHash: 'cert',
);

class _FakeBridge implements GestureNativeBridge {
  final List<({String op, Map<String, Object?> args})> calls = [];
  GestureResult next = const GestureResult(dispatched: true);

  @override
  Future<GestureResult> tap({
    required int displayId,
    required double x,
    required double y,
  }) async {
    calls.add((
      op: 'tap',
      args: <String, Object?>{'displayId': displayId, 'x': x, 'y': y},
    ));
    return next;
  }

  @override
  Future<GestureResult> swipe({
    required int displayId,
    required double fromX,
    required double fromY,
    required double toX,
    required double toY,
    required int durationMs,
  }) async {
    calls.add((
      op: 'swipe',
      args: <String, Object?>{
        'displayId': displayId,
        'fromX': fromX,
        'fromY': fromY,
        'toX': toX,
        'toY': toY,
        'durationMs': durationMs,
      },
    ));
    return next;
  }

  @override
  Future<GestureResult> longPress({
    required int displayId,
    required double x,
    required double y,
    required int durationMs,
  }) async {
    calls.add((
      op: 'longPress',
      args: <String, Object?>{
        'displayId': displayId,
        'x': x,
        'y': y,
        'durationMs': durationMs,
      },
    ));
    return next;
  }

  @override
  Future<GestureResult> text({
    required int displayId,
    required String text,
  }) async {
    calls.add((
      op: 'text',
      args: <String, Object?>{'displayId': displayId, 'text': text},
    ));
    return next;
  }

  @override
  Future<GestureResult> key({
    required int displayId,
    required int keycode,
  }) async {
    calls.add((
      op: 'key',
      args: <String, Object?>{'displayId': displayId, 'keycode': keycode},
    ));
    return next;
  }

  @override
  Future<GestureResult> ptrDown({
    required int displayId,
    required double x,
    required double y,
  }) async {
    calls.add((
      op: 'ptrDown',
      args: <String, Object?>{'displayId': displayId, 'x': x, 'y': y},
    ));
    return next;
  }

  @override
  Future<GestureResult> ptrMove({
    required int displayId,
    required double x,
    required double y,
  }) async {
    calls.add((
      op: 'ptrMove',
      args: <String, Object?>{'displayId': displayId, 'x': x, 'y': y},
    ));
    return next;
  }

  @override
  Future<GestureResult> ptrUp({required double x, required double y}) async {
    calls.add((op: 'ptrUp', args: <String, Object?>{'x': x, 'y': y}));
    return next;
  }

  @override
  Future<GestureResult> ptrCancel() async {
    calls.add((op: 'ptrCancel', args: <String, Object?>{}));
    return next;
  }
}

void main() {
  group('GestureFamily', () {
    late _FakeBridge bridge;
    late GestureFamily family;

    setUp(() {
      bridge = _FakeBridge();
      family = GestureFamily(bridge: bridge);
    });

    test('familyId is "gesture" with the expected permission id', () {
      expect(family.familyId, 'gesture');
      expect(family.permissionIds, {'gesture.dispatch'});
      expect(
        family.secondaryAllowed,
        isFalse,
        reason: 'must not be exposed to a child surface',
      );
    });

    test('every handler is requiresStepUp=true (truthful flag)', () {
      // All gesture ops are destructive. The flag is truthful;
      // the gate's `requireBinding` switch decides whether step-up
      // means a per-action cap (legacy) or install-time consent
      // (family path). See `MiniAppGate.gateTier2` for the split.
      for (final entry in family.handlers.entries) {
        expect(
          entry.value.requiresStepUp,
          isTrue,
          reason: 'handler ${entry.key} should be truthful about destruction',
        );
      }
    });

    test('tap forwards displayId + coords as doubles', () async {
      final r = await family.handlers['tap']!.execute(
        const BridgeCall(
          familyId: 'gesture',
          op: 'tap',
          params: {'displayId': 4, 'x': 960, 'y': 360},
          session: _session,
        ),
      );
      expect(r['dispatched'], isTrue);
      expect(bridge.calls, hasLength(1));
      expect(bridge.calls.first.op, 'tap');
      expect(bridge.calls.first.args['displayId'], 4);
      expect(bridge.calls.first.args['x'], 960.0);
      expect(bridge.calls.first.args['y'], 360.0);
    });

    test('swipe forwards every coordinate slot', () async {
      await family.handlers['swipe']!.execute(
        const BridgeCall(
          familyId: 'gesture',
          op: 'swipe',
          params: {
            'displayId': 4,
            'fromX': 100,
            'fromY': 200,
            'toX': 1820,
            'toY': 200,
            'durationMs': 250,
          },
          session: _session,
        ),
      );
      expect(bridge.calls.first.op, 'swipe');
      expect(bridge.calls.first.args['fromX'], 100.0);
      expect(bridge.calls.first.args['toX'], 1820.0);
      expect(bridge.calls.first.args['durationMs'], 250);
    });

    test('longPress forwards durationMs', () async {
      await family.handlers['longPress']!.execute(
        const BridgeCall(
          familyId: 'gesture',
          op: 'longPress',
          params: {'displayId': 4, 'x': 100, 'y': 200, 'durationMs': 1500},
          session: _session,
        ),
      );
      expect(bridge.calls.first.op, 'longPress');
      expect(bridge.calls.first.args['durationMs'], 1500);
    });

    test('dispatched=false passes through with reason', () async {
      bridge.next = const GestureResult(
        dispatched: false,
        reason: 'accessibility_disabled',
      );
      final r = await family.handlers['tap']!.execute(
        const BridgeCall(
          familyId: 'gesture',
          op: 'tap',
          params: {'displayId': 4, 'x': 0, 'y': 0},
          session: _session,
        ),
      );
      expect(r['dispatched'], isFalse);
      expect(r['reason'], 'accessibility_disabled');
    });
  });
}
