import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/cluster_touchpad/state/cluster_touchpad_controller.dart';
import 'package:ilink/features/cluster_touchpad/state/cluster_trackpad_controller.dart';
import 'package:ilink/features/cluster_touchpad/state/relative_trackpad.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_native_bridge.dart';
import 'package:ilink/features/mini_apps/runtime/gesture_native_bridge.dart';

/// Records gesture-channel calls; `streamResult` lets a test simulate a car
/// where the daemon FAST tier can't stream (so ptr* report unavailable).
class _RecordingGesture implements GestureNativeBridge {
  _RecordingGesture({
    this.streamResult = const GestureResult(dispatched: true),
  });

  final GestureResult streamResult;
  final List<String> ops = [];
  final List<Map<String, Object?>> args = [];

  void _rec(String op, Map<String, Object?> a) {
    ops.add(op);
    args.add(a);
  }

  @override
  Future<GestureResult> tap({
    required int displayId,
    required double x,
    required double y,
  }) async {
    _rec('tap', {'displayId': displayId, 'x': x, 'y': y});
    return const GestureResult(dispatched: true, path: 'daemon');
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
    _rec('swipe', {'fromX': fromX, 'fromY': fromY, 'toX': toX, 'toY': toY});
    return const GestureResult(dispatched: true, path: 'daemon');
  }

  @override
  Future<GestureResult> longPress({
    required int displayId,
    required double x,
    required double y,
    required int durationMs,
  }) async {
    _rec('longPress', {'x': x, 'y': y});
    return const GestureResult(dispatched: true);
  }

  @override
  Future<GestureResult> text({
    required int displayId,
    required String text,
  }) async {
    _rec('text', {'text': text});
    return const GestureResult(dispatched: true);
  }

  @override
  Future<GestureResult> key({
    required int displayId,
    required int keycode,
  }) async {
    _rec('key', {'keycode': keycode});
    return const GestureResult(dispatched: true, path: 'daemon');
  }

  @override
  Future<GestureResult> ptrDown({
    required int displayId,
    required double x,
    required double y,
  }) async {
    _rec('ptrDown', {'x': x, 'y': y});
    return streamResult;
  }

  @override
  Future<GestureResult> ptrMove({
    required int displayId,
    required double x,
    required double y,
  }) async {
    _rec('ptrMove', {'x': x, 'y': y});
    return streamResult;
  }

  @override
  Future<GestureResult> ptrUp({required double x, required double y}) async {
    _rec('ptrUp', {'x': x, 'y': y});
    return streamResult;
  }

  @override
  Future<GestureResult> ptrCancel() async {
    _rec('ptrCancel', {});
    return streamResult;
  }
}

/// Cursor-overlay calls are display-only; swallow them.
class _NoopPkg implements PkgNativeBridge {
  @override
  dynamic noSuchMethod(Invocation i) => Future<bool>.value(true);
}

ClusterTouchpadTarget _target() => const ClusterTouchpadTarget(
  displayId: 5,
  cursorDisplayId: 5,
  inputDisplayId: 3,
  width: 1920,
  height: 720,
  label: 'Cluster',
);

ClusterTrackpadController _make(_RecordingGesture g) =>
    ClusterTrackpadController(
      forwarder: ClusterTouchpadForwarder(g, _NoopPkg(), _target()),
      trackpad: RelativeTrackpad(width: 1920, height: 720),
    );

void main() {
  group('ClusterTrackpadController', () {
    test('single quick tap → click at the cursor centre', () async {
      final g = _RecordingGesture();
      final c = _make(g);
      await c.pointerDown(1, const Offset(10, 10), 0);
      final action = await c.pointerUp(1, 100);
      expect(action, TrackpadAction.tap);
      expect(g.ops, contains('tap'));
      // Cursor started centred and never moved → click at 960×360 (input id 3).
      final tap = g.args[g.ops.indexOf('tap')];
      expect(tap['x'], 960.0);
      expect(tap['y'], 360.0);
    });

    test(
      'single drag past the tap slop → no click, only cursor reposition',
      () async {
        final g = _RecordingGesture();
        final c = _make(g);
        await c.pointerDown(1, const Offset(0, 0), 0);
        await c.pointerMove(
          1,
          const Offset(120, 120),
          const Size(400, 400),
          16,
        );
        final action = await c.pointerUp(1, 50);
        expect(action, TrackpadAction.none);
        expect(g.ops, isNot(contains('tap')));
      },
    );

    test('held too long → not a tap', () async {
      final g = _RecordingGesture();
      final c = _make(g);
      await c.pointerDown(1, const Offset(0, 0), 0);
      final action = await c.pointerUp(1, 999); // > tapTimeoutMs
      expect(action, TrackpadAction.none);
      expect(g.ops, isNot(contains('tap')));
    });

    test('two-finger tap → BACK key, no stray pointer down', () async {
      final g = _RecordingGesture();
      final c = _make(g);
      await c.pointerDown(1, const Offset(0, 0), 0);
      await c.pointerDown(2, const Offset(20, 0), 5);
      await c.pointerUp(1, 10);
      final action = await c.pointerUp(2, 15);
      expect(action, TrackpadAction.back);
      expect(g.ops, contains('key'));
      expect(g.args[g.ops.indexOf('key')]['keycode'], 4); // KEYCODE_BACK
      // Crucially: the deferred-drag design never injected a DOWN.
      expect(g.ops, isNot(contains('ptrDown')));
    });

    test('two-finger drag (streaming) → ptrDown/move/up', () async {
      final g = _RecordingGesture();
      final c = _make(g);
      await c.pointerDown(1, const Offset(0, 0), 0);
      await c.pointerDown(2, const Offset(20, 0), 5);
      await c.pointerMove(1, const Offset(200, 0), const Size(400, 400), 16);
      await c.pointerUp(1, 20);
      final action = await c.pointerUp(2, 25);
      expect(action, TrackpadAction.dragEnd);
      expect(g.ops, containsAllInOrder(['ptrDown', 'ptrMove', 'ptrUp']));
      expect(g.ops, isNot(contains('swipe')));
    });

    test(
      'two-finger drag without streaming → one coalesced fallback swipe',
      () async {
        final g = _RecordingGesture(
          streamResult: const GestureResult(
            dispatched: false,
            reason: 'stream_unavailable',
          ),
        );
        final c = _make(g);
        await c.pointerDown(1, const Offset(0, 0), 0);
        await c.pointerDown(2, const Offset(20, 0), 5);
        await c.pointerMove(1, const Offset(200, 0), const Size(400, 400), 16);
        await c.pointerUp(1, 20);
        final action = await c.pointerUp(2, 25);
        expect(action, TrackpadAction.dragEnd);
        // No streamed moves; exactly one coalesced swipe over the drag span.
        expect(g.ops, contains('swipe'));
        expect(g.ops.where((o) => o == 'ptrMove'), isEmpty);
      },
    );

    test('cancel mid-drag releases the streamed pointer', () async {
      final g = _RecordingGesture();
      final c = _make(g);
      await c.pointerDown(1, const Offset(0, 0), 0);
      await c.pointerDown(2, const Offset(20, 0), 5);
      await c.pointerMove(1, const Offset(200, 0), const Size(400, 400), 16);
      await c.pointerCancel(1);
      await c.pointerCancel(2);
      expect(g.ops, contains('ptrCancel'));
    });
  });
}
