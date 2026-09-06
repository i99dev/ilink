import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/cluster_touchpad/state/relative_trackpad.dart';

void main() {
  group('RelativeTrackpad', () {
    test('starts centered by default', () {
      final pad = RelativeTrackpad(width: 1920, height: 720);
      expect(pad.cursorX, 960);
      expect(pad.cursorY, 360);
    });

    test('honours an explicit start position', () {
      final pad = RelativeTrackpad(
        width: 1920,
        height: 720,
        startX: 100,
        startY: 50,
      );
      expect(pad.cursorX, 100);
      expect(pad.cursorY, 50);
    });

    test('a full-pad rightward delta moves ~one cluster width at gain 1', () {
      final pad = RelativeTrackpad(
        width: 1000,
        height: 1000,
        startX: 0,
        startY: 500,
        baseGain: 1.0,
        accelPerUnitSpeed: 0, // isolate base gain
      );
      // Drag the full pad width (200 px pad) → +1000 cluster px at gain 1,
      // clamped to the right edge.
      pad.applyPadDelta(200, 0, 200, 200);
      expect(pad.cursorX, 1000);
    });

    test('clamps to the cluster bounds', () {
      final pad = RelativeTrackpad(
        width: 800,
        height: 480,
        startX: 10,
        startY: 10,
        accelPerUnitSpeed: 0,
      );
      pad.applyPadDelta(-500, -500, 200, 200); // way past top-left
      expect(pad.cursorX, 0);
      expect(pad.cursorY, 0);
      pad.applyPadDelta(5000, 5000, 200, 200); // way past bottom-right
      expect(pad.cursorX, 800);
      expect(pad.cursorY, 480);
    });

    test('acceleration: a faster flick travels further than a slow one', () {
      Offset moveOnce(double dx) {
        final pad = RelativeTrackpad(
          width: 4000,
          height: 1000,
          startX: 0,
          startY: 500,
          baseGain: 1.0,
          accelPerUnitSpeed: 2.0,
        );
        // Same total distance, but a single big step (fast) vs reaching it in
        // one event. Compare a small vs large single delta on the same pad.
        pad.applyPadDelta(dx, 0, 400, 400);
        return pad.cursor;
      }

      // Two events of equal NET distance but different per-event speed: a
      // single 200px step (fast) overshoots two 100px steps' base movement
      // because gain scales with per-event speed.
      final fast = moveOnce(200).dx; // speed 0.5 → gain 1 + 1.0 = 2.0
      final slow = moveOnce(100).dx; // speed 0.25 → gain 1 + 0.5 = 1.5
      // fast = 0.5 * 4000 * 2.0 = 4000 (clamped) ; slow = 0.25*4000*1.5 = 1500
      expect(fast, greaterThan(slow));
    });

    test('reset recentres and clamps', () {
      final pad = RelativeTrackpad(width: 1920, height: 720);
      pad.applyPadDelta(100, 100, 200, 200);
      pad.reset();
      expect(pad.cursorX, 960);
      expect(pad.cursorY, 360);
      pad.reset(x: -50, y: 9999);
      expect(pad.cursorX, 0);
      expect(pad.cursorY, 720);
    });

    test('zero pad size is a no-op (no NaN)', () {
      final pad = RelativeTrackpad(width: 1920, height: 720);
      final before = pad.cursor;
      pad.applyPadDelta(10, 10, 0, 0);
      expect(pad.cursor, before);
    });
  });
}
