import 'dart:ui' show Offset, Size;

import 'cluster_touchpad_controller.dart';
import 'relative_trackpad.dart';

/// What a completed gesture resolved to — returned from [ClusterTrackpadController]
/// pointer methods so the UI can surface status and tests can assert intent
/// without a real cluster.
enum TrackpadAction {
  /// Nothing terminal happened (a move, or a non-terminal pointer change).
  none,

  /// Single-finger tap → click injected at the cursor.
  tap,

  /// Two-finger tap → BACK key.
  back,

  /// A drag finished (streamed ptrUp, or a coalesced fallback swipe).
  dragEnd,
}

/// Android `KeyEvent.KEYCODE_BACK`.
const int _kKeycodeBack = 4;

/// Drives the relative-trackpad gesture model on top of a
/// [ClusterTouchpadForwarder] + [RelativeTrackpad]. Widget-agnostic and
/// clock-injected so it unit-tests against a fake forwarder.
///
/// Model (one finger = move + click, two fingers = drag/scroll + back):
///   * **1 finger move** → moves the cursor relatively (no injection); the
///     overlay dot follows (throttled).
///   * **1 finger tap** (travel &lt; [tapSlopPx], held &lt; [tapTimeoutMs]) →
///     click at the cursor.
///   * **2 fingers** → a drag at the cursor: on the transition to two fingers
///     we open a streamed pointer session ([ClusterTouchpadForwarder.ptrDown]);
///     the primary finger's motion streams [ClusterTouchpadForwarder.ptrMove]
///     at the cursor so the cluster content scrolls/drags; lift =
///     [ClusterTouchpadForwarder.ptrUp]. A low-travel two-finger tap = BACK.
///   * If the daemon FAST tier can't stream on this car, a two-finger drag
///     degrades to one coalesced [ClusterTouchpadForwarder.swipeFallback] from
///     the drag's start cursor to its end cursor.
class ClusterTrackpadController {
  ClusterTrackpadController({
    required this.forwarder,
    required RelativeTrackpad trackpad,
    this.tapSlopPx = 14.0,
    this.tapTimeoutMs = 320,
    this.cursorThrottleMs = 16,
  }) : _pad = trackpad;

  final ClusterTouchpadForwarder forwarder;
  final RelativeTrackpad _pad;

  /// Max accumulated primary-finger travel (pad px) still classed as a tap.
  final double tapSlopPx;

  /// Max press duration still classed as a tap.
  final int tapTimeoutMs;

  /// Min gap between cursor-overlay updates (the dot need not exceed display
  /// refresh; injection moves are not throttled here).
  final int cursorThrottleMs;

  // Active pointers → their last local position (pad px).
  final Map<int, Offset> _pointers = <int, Offset>{};
  int? _primary;
  double _travelPx = 0;
  int _downAtMs = 0;
  bool _twoFinger = false; // two fingers touched at some point this gesture
  bool _dragging = false; // a drag has actually started (DOWN injected/armed)
  Offset _dragStartCursor = Offset.zero;
  int _lastCursorMoveMs = 0;

  Offset get cursor => _pad.cursor;

  /// Paint the cursor overlay for the session. Call once on open.
  Future<void> begin() async {
    await forwarder.showCursor();
    await forwarder.moveCursor(_pad.cursorX, _pad.cursorY);
  }

  /// Tear down — hide the overlay and lift any in-flight drag.
  Future<void> end() async {
    if (_dragging) {
      await forwarder.ptrCancel();
      _dragging = false;
    }
    await forwarder.hideCursor();
  }

  Future<TrackpadAction> pointerDown(int id, Offset local, int nowMs) async {
    _pointers[id] = local;
    if (_pointers.length == 1) {
      _primary = id;
      _travelPx = 0;
      _downAtMs = nowMs;
      _twoFinger = false;
      _dragging = false;
    }
    // Transition to two fingers → ARM a drag (remember the cursor) but do NOT
    // inject a DOWN yet: a two-finger TAP (no travel) must resolve to BACK, not
    // a stray pressed pointer. The drag opens on the first move (pointerMove).
    if (_pointers.length == 2) {
      _twoFinger = true;
      _dragStartCursor = _pad.cursor;
    }
    return TrackpadAction.none;
  }

  Future<TrackpadAction> pointerMove(
    int id,
    Offset local,
    Size padSize,
    int nowMs,
  ) async {
    final prev = _pointers[id];
    _pointers[id] = local;
    // Only the primary finger drives the cursor (a second finger is just the
    // "drag" modifier; tracking both would fight the cursor).
    if (id != _primary || prev == null) return TrackpadAction.none;
    final delta = local - prev;
    _travelPx += delta.distance;
    _pad.applyPadDelta(delta.dx, delta.dy, padSize.width, padSize.height);
    // Throttle the overlay dot; injection moves below are not throttled.
    if (nowMs - _lastCursorMoveMs >= cursorThrottleMs) {
      _lastCursorMoveMs = nowMs;
      // ignore: unawaited_futures
      forwarder.moveCursor(_pad.cursorX, _pad.cursorY);
    }
    // First real move with two fingers down → open the drag now (ACTION_DOWN
    // at where the second finger landed). Deferring to here means a two-finger
    // tap never injects a stray press. `streamingAvailable` is set by ptrDown;
    // if the daemon can't stream we still mark `_dragging` so _finalize emits a
    // coalesced fallback swipe.
    if (_twoFinger && !_dragging) {
      _dragging = true;
      await forwarder.ptrDown(
        _dragStartCursor.dx.round(),
        _dragStartCursor.dy.round(),
      );
    }
    // Streamed drag: follow the cursor with injected MOVE frames.
    if (_dragging && forwarder.streamingAvailable) {
      // ignore: unawaited_futures
      forwarder.ptrMove(_pad.cursorX, _pad.cursorY);
    }
    return TrackpadAction.none;
  }

  Future<TrackpadAction> pointerUp(int id, int nowMs) async {
    _pointers.remove(id);
    if (_pointers.isNotEmpty) {
      // Other fingers still down — not a terminal event yet. If the primary
      // lifted first, hand primacy to a remaining finger so the cursor keeps
      // tracking (its next move seeds a fresh delta).
      if (id == _primary) _primary = _pointers.keys.first;
      return TrackpadAction.none;
    }
    return _finalize(nowMs);
  }

  Future<TrackpadAction> _finalize(int nowMs) async {
    final lowTravel = _travelPx < tapSlopPx;
    final quick = nowMs - _downAtMs < tapTimeoutMs;
    TrackpadAction action = TrackpadAction.none;

    if (_twoFinger) {
      if (!_dragging) {
        // Two fingers down but never dragged → a two-finger tap = BACK.
        await forwarder.key(_kKeycodeBack);
        action = TrackpadAction.back;
      } else if (forwarder.streamingAvailable) {
        await forwarder.ptrUp(_pad.cursorX, _pad.cursorY);
        action = TrackpadAction.dragEnd;
      } else {
        // Daemon couldn't stream → one coalesced swipe over the drag span.
        await forwarder.swipeFallback(
          _dragStartCursor.dx.round(),
          _dragStartCursor.dy.round(),
          _pad.cursorX,
          _pad.cursorY,
        );
        action = TrackpadAction.dragEnd;
      }
    } else if (lowTravel && quick) {
      await forwarder.tapAt(_pad.cursorX, _pad.cursorY);
      action = TrackpadAction.tap;
    }
    // else: a single-finger move only repositioned the cursor — no injection.

    _resetGesture();
    return action;
  }

  Future<void> pointerCancel(int id) async {
    _pointers.remove(id);
    if (_pointers.isEmpty) {
      if (_dragging) await forwarder.ptrCancel();
      _resetGesture();
    }
  }

  void _resetGesture() {
    _pointers.clear();
    _primary = null;
    _travelPx = 0;
    _twoFinger = false;
    _dragging = false;
  }
}
