/// Thin Dart wrapper around the `ilink/gesture` MethodChannel.
///
/// THIS IS THE ONLY FILE in the `gesture/` Dart layer that imports
/// `package:flutter/services.dart`. [GestureFamily] and any test
/// against it depend on the [GestureNativeBridge] interface, never
/// on `MethodChannel` directly. Project memory
/// `feedback_engineering_axes`: keep platform imports isolated.
library;

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';

/// Result of a single gesture dispatch. `dispatched=false` means the
/// active tier refused; the `reason` surfaces the cause so the SDK can
/// show actionable text. `path` names which tier handled it —
/// `"daemon"` (FAST injectInputEvent), `"a11y"` (dispatchGesture), or
/// `"adb"` (`input -d N`) — purely for diagnostics / on-car triage.
class GestureResult {
  const GestureResult({required this.dispatched, this.reason, this.path});

  final bool dispatched;
  final String? reason;
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
    'dispatched': dispatched,
    if (reason != null) 'reason': reason,
    if (path != null) 'path': path,
  };

  factory GestureResult.fromMap(Map<String, Object?> map) => GestureResult(
    dispatched: map['dispatched'] as bool? ?? false,
    reason: map['reason'] as String?,
    path: map['path'] as String?,
  );
}

/// Interface seam. Tests provide a fake [GestureNativeBridge];
/// production wires [PlatformGestureNativeBridge].
abstract class GestureNativeBridge {
  Future<GestureResult> tap({
    required int displayId,
    required double x,
    required double y,
  });

  Future<GestureResult> swipe({
    required int displayId,
    required double fromX,
    required double fromY,
    required double toX,
    required double toY,
    required int durationMs,
  });

  Future<GestureResult> longPress({
    required int displayId,
    required double x,
    required double y,
    required int durationMs,
  });

  /// Type a string into the focused input on `displayId`. UTF-8 — works
  /// for English, Arabic, anything the ADB `input text` accepts.
  Future<GestureResult> text({required int displayId, required String text});

  /// Send an Android keycode to the focused input on `displayId`.
  /// Standard `KeyEvent.KEYCODE_*` constants — 67 = DEL (backspace),
  /// 66 = ENTER, 62 = SPACE, 61 = TAB, 4 = BACK.
  Future<GestureResult> key({required int displayId, required int keycode});

  /// Streamed pointer session — the relative-trackpad drag path. Only the
  /// daemon tier can stream (a11y/ADB are discrete), so when the daemon is
  /// unavailable these return `dispatched=false, reason="stream_unavailable"`
  /// and the caller must fall back to a coalesced [swipe].
  ///
  /// Lifecycle: [ptrDown] → many [ptrMove] → [ptrUp] (or [ptrCancel]). The
  /// native side owns the gesture `downTime`; the caller only streams pixel
  /// coordinates on the target's input display. [ptrMove] is sent
  /// fire-and-forget on the native side, so its result is best-effort.
  Future<GestureResult> ptrDown({
    required int displayId,
    required double x,
    required double y,
  });
  Future<GestureResult> ptrMove({
    required int displayId,
    required double x,
    required double y,
  });
  Future<GestureResult> ptrUp({required double x, required double y});
  Future<GestureResult> ptrCancel();
}

/// Production impl — talks to `InputPlatformPlugin.kt`.
class PlatformGestureNativeBridge implements GestureNativeBridge {
  PlatformGestureNativeBridge({MethodChannel? methodChannel})
    : _method = methodChannel ?? const MethodChannel('ilink/gesture');

  final MethodChannel _method;

  @override
  Future<GestureResult> tap({
    required int displayId,
    required double x,
    required double y,
  }) async {
    Observability.breadcrumb(
      category: 'gesture.native',
      message: 'tap',
      data: {'displayId': displayId},
    );
    final raw = await _method.invokeMapMethod<String, Object?>('tap', {
      'displayId': displayId,
      'x': x,
      'y': y,
    });
    return GestureResult.fromMap(raw ?? const {});
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
    Observability.breadcrumb(
      category: 'gesture.native',
      message: 'swipe',
      data: {'displayId': displayId, 'durationMs': durationMs},
    );
    final raw = await _method.invokeMapMethod<String, Object?>('swipe', {
      'displayId': displayId,
      'fromX': fromX,
      'fromY': fromY,
      'toX': toX,
      'toY': toY,
      'durationMs': durationMs,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> longPress({
    required int displayId,
    required double x,
    required double y,
    required int durationMs,
  }) async {
    Observability.breadcrumb(
      category: 'gesture.native',
      message: 'longPress',
      data: {'displayId': displayId, 'durationMs': durationMs},
    );
    final raw = await _method.invokeMapMethod<String, Object?>('longPress', {
      'displayId': displayId,
      'x': x,
      'y': y,
      'durationMs': durationMs,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> text({
    required int displayId,
    required String text,
  }) async {
    Observability.breadcrumb(
      category: 'gesture.native',
      message: 'text',
      // Don't log the text content — could be PII (search terms,
      // partial credentials a user typed in the wrong place).
      data: {'displayId': displayId, 'len': text.length},
    );
    final raw = await _method.invokeMapMethod<String, Object?>('text', {
      'displayId': displayId,
      'text': text,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> key({
    required int displayId,
    required int keycode,
  }) async {
    Observability.breadcrumb(
      category: 'gesture.native',
      message: 'key',
      data: {'displayId': displayId, 'keycode': keycode},
    );
    final raw = await _method.invokeMapMethod<String, Object?>('key', {
      'displayId': displayId,
      'keycode': keycode,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> ptrDown({
    required int displayId,
    required double x,
    required double y,
  }) async {
    final raw = await _method.invokeMapMethod<String, Object?>('ptr', {
      'phase': 'down',
      'displayId': displayId,
      'x': x,
      'y': y,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> ptrMove({
    required int displayId,
    required double x,
    required double y,
  }) async {
    // No breadcrumb — move frames fire at display refresh rate; logging each
    // would bury the signal. The native side streams these fire-and-forget.
    final raw = await _method.invokeMapMethod<String, Object?>('ptr', {
      'phase': 'move',
      'displayId': displayId,
      'x': x,
      'y': y,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> ptrUp({required double x, required double y}) async {
    final raw = await _method.invokeMapMethod<String, Object?>('ptr', {
      'phase': 'up',
      'x': x,
      'y': y,
    });
    return GestureResult.fromMap(raw ?? const {});
  }

  @override
  Future<GestureResult> ptrCancel() async {
    final raw = await _method.invokeMapMethod<String, Object?>('ptr', {
      'phase': 'cancel',
    });
    return GestureResult.fromMap(raw ?? const {});
  }
}
