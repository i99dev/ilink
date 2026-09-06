import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Pure relative-trackpad cursor model — no Flutter widget deps, fully
/// unit-testable.
///
/// The cluster is not touch-capable, so the IVI sheet is a *laptop-style*
/// trackpad: a finger drag moves a cursor RELATIVELY (not 1:1 absolute), a
/// quick low-travel tap clicks at the cursor, and the cursor is clamped to the
/// cluster's pixel bounds. This is the input model the daemon FAST path makes
/// viable — every cursor move streams as a cheap overlay update, and a click /
/// drag injects a real MotionEvent at the cursor.
///
/// Coordinate spaces:
///   * **pad px** — the on-screen touchpad widget's local pixels (varies by
///     sheet size). The caller feeds raw finger deltas in this space.
///   * **cluster px** — the driver cluster's real resolution ([width] ×
///     [height]). The cursor lives here; clicks/drags inject here.
///
/// A pad-px delta is first normalised by the pad size the caller passes, then
/// scaled to cluster px and shaped by a speed-dependent gain so slow drags are
/// precise and fast flicks cross the screen — the standard pointer-accel curve.
class RelativeTrackpad {
  RelativeTrackpad({
    required this.width,
    required this.height,
    double? startX,
    double? startY,
    this.baseGain = 1.0,
    this.accelPerUnitSpeed = 1.4,
    this.maxGain = 3.0,
  }) : _x = startX ?? width / 2.0,
       _y = startY ?? height / 2.0;

  /// Cluster pixel extent the cursor is clamped within.
  final int width;
  final int height;

  /// Gain at zero speed — 1.0 means a full-width pad swipe moves the cursor a
  /// full cluster width (1:1 after size-normalisation). Below 1.0 = finer.
  final double baseGain;

  /// Extra gain added per unit of normalised speed (fraction of the pad
  /// traversed per move event). Drives the acceleration curve.
  final double accelPerUnitSpeed;

  /// Hard ceiling on the accel gain so a very fast flick can't teleport
  /// unpredictably.
  final double maxGain;

  double _x;
  double _y;

  Offset get cursor => Offset(_x, _y);
  int get cursorX => _x.round();
  int get cursorY => _y.round();

  /// Recentre the cursor (e.g. on open). Clamped.
  void reset({double? x, double? y}) {
    _x = (x ?? width / 2.0).clamp(0.0, width.toDouble());
    _y = (y ?? height / 2.0).clamp(0.0, height.toDouble());
  }

  /// Apply a finger delta measured in pad pixels, given the pad's pixel size,
  /// and return the new cursor position (cluster px, clamped).
  ///
  /// [padW]/[padH] normalise the delta so the gain is independent of sheet
  /// size; the speed-accel curve then shapes it. Returns [cursor] for chaining.
  Offset applyPadDelta(double dxPad, double dyPad, double padW, double padH) {
    if (padW <= 0 || padH <= 0) return cursor;
    // Normalised delta: fraction of the pad traversed this event.
    final nx = dxPad / padW;
    final ny = dyPad / padH;
    final speed = math.sqrt(nx * nx + ny * ny);
    final gain = math.min(baseGain + accelPerUnitSpeed * speed, maxGain);
    _x = (_x + nx * width * gain).clamp(0.0, width.toDouble());
    _y = (_y + ny * height * gain).clamp(0.0, height.toDouble());
    return cursor;
  }
}
