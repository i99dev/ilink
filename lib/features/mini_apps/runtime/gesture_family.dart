/// `gesture` family — synthetic input on a target display. The
/// realistic capability for non-system-signed apps targeting the
/// cluster: pixels are signature-gated by the XDJA composer
/// (Leopard 8 verified — see project memory
/// `project_leopard8_cluster_signature_gate`), but
/// `AccessibilityService.dispatchGesture(displayId)` is a separate
/// permission system that DOES work without signature gating.
///
/// Same capability i99dev ships in their working mode (per their
/// `RemoteControlAccessibilityService` class). Combined with the
/// [CursorFamily]'s IVI-side touchpad-style cursor, this is what
/// "remote control of cluster" mini-apps build on.
///
/// All three handlers are tier-2 with `requiresStepUp: true` because
/// synthetic input is the most dangerous primitive in the surface.
/// The gate ([MiniAppGate.gateTier2]) splits step-up enforcement by
/// binding model:
///
///   * Family path (`requireBinding: false`) — manifest-backed
///     install IS the step-up. The user explicitly approved
///     `gesture.dispatch` at install time; the gate skips the
///     per-action prompt that would otherwise fire on every drag.
///   * Legacy `_admin.exec` (`requireBinding: true`) — the gate
///     refuses so the dispatcher can fetch a fresh per-action cap.
///
/// This split lives in one place (the gate); handlers stay truthful
/// about being destructive.
///
/// Pure-Dart class — no platform imports. The `*NativeBridge`
/// abstraction is the only seam to native code.
library;

import '../../admin_mini_apps/domain/admin_op.dart'
    show IntParamRule, NumberParamRule, ParamRule, RegexParamRule;
import '../bridge/mini_app_family.dart';
import 'gesture_native_bridge.dart';

class GestureFamily extends MiniAppFamily {
  GestureFamily({GestureNativeBridge? bridge})
    : _bridge = bridge ?? PlatformGestureNativeBridge();

  final GestureNativeBridge _bridge;

  @override
  String get familyId => 'gesture';

  @override
  Set<String> get permissionIds => const {'gesture.dispatch'};

  // Privileged — must NOT be exposed to a secondary surface. A child
  // surface that could synthesize taps would be an escalation gadget.
  @override
  bool get secondaryAllowed => false;

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'tap': _TapHandler(_bridge),
    'swipe': _SwipeHandler(_bridge),
    'longPress': _LongPressHandler(_bridge),
    'text': _TextHandler(_bridge),
    'key': _KeyHandler(_bridge),
  };
}

// Coordinate slots use NumberParamRule because JS numbers cross the
// MethodChannel as doubles; an `IntParamRule` would reject every
// SDK-issued tap (`expected int, got double`). Real bounds come from
// the target display's resolution; we don't gate on bounds here
// because the AccessibilityService does it (out-of-bounds taps just
// fail to dispatch). Min=-1 / max=10000 catches obviously-bad input
// without coupling the gate to display geometry.
const _coord = NumberParamRule(min: -1, max: 10_000);
const _displayId = IntParamRule(min: 0, max: 100);

class _TapHandler implements FamilyHandler {
  _TapHandler(this._bridge);
  final GestureNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'displayId': _displayId,
    'x': _coord,
    'y': _coord,
  };

  // Truthful flag — synthetic input IS destructive. The gate's
  // [requireBinding] switch routes enforcement: per-action cap on the
  // legacy path, install-time consent on the family path.
  @override
  bool get requiresStepUp => true;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final r = await _bridge.tap(
      displayId: (call.params['displayId']! as int),
      x: (call.params['x']! as num).toDouble(),
      y: (call.params['y']! as num).toDouble(),
    );
    return r.toJson();
  }
}

class _SwipeHandler implements FamilyHandler {
  _SwipeHandler(this._bridge);
  final GestureNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'displayId': _displayId,
    'fromX': _coord,
    'fromY': _coord,
    'toX': _coord,
    'toY': _coord,
    // Cap duration at 10s — anything longer is almost certainly a bug.
    'durationMs': IntParamRule(min: 1, max: 10_000, defaultValue: 300),
  };

  // Truthful flag — synthetic input IS destructive. The gate's
  // [requireBinding] switch routes enforcement: per-action cap on the
  // legacy path, install-time consent on the family path.
  @override
  bool get requiresStepUp => true;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final r = await _bridge.swipe(
      displayId: call.params['displayId']! as int,
      fromX: (call.params['fromX']! as num).toDouble(),
      fromY: (call.params['fromY']! as num).toDouble(),
      toX: (call.params['toX']! as num).toDouble(),
      toY: (call.params['toY']! as num).toDouble(),
      durationMs: call.params['durationMs']! as int,
    );
    return r.toJson();
  }
}

class _TextHandler implements FamilyHandler {
  _TextHandler(this._bridge);
  final GestureNativeBridge _bridge;

  // Bound the text payload to something an interactive use case wants —
  // a 1024-char tap-to-type field is already absurd; capping here means
  // a misbehaving mini-app can't pump multi-MB strings through ADB.
  static final _textRule = RegexParamRule(pattern: r'^.{0,1024}$');

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'displayId': _displayId,
    'text': _textRule,
  };

  @override
  bool get requiresStepUp => true;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final r = await _bridge.text(
      displayId: call.params['displayId']! as int,
      text: call.params['text']! as String,
    );
    return r.toJson();
  }
}

class _KeyHandler implements FamilyHandler {
  _KeyHandler(this._bridge);
  final GestureNativeBridge _bridge;

  // Standard Android `KeyEvent.KEYCODE_*` range. 1..288 covers every
  // documented keycode (KEYCODE_REFRESH=285, KEYCODE_SOFT_SLEEP=276 etc).
  static const _keycodeRule = IntParamRule(min: 1, max: 288);

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'displayId': _displayId,
    'keycode': _keycodeRule,
  };

  @override
  bool get requiresStepUp => true;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final r = await _bridge.key(
      displayId: call.params['displayId']! as int,
      keycode: call.params['keycode']! as int,
    );
    return r.toJson();
  }
}

class _LongPressHandler implements FamilyHandler {
  _LongPressHandler(this._bridge);
  final GestureNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'displayId': _displayId,
    'x': _coord,
    'y': _coord,
    'durationMs': IntParamRule(min: 100, max: 10_000, defaultValue: 800),
  };

  // Truthful flag — synthetic input IS destructive. The gate's
  // [requireBinding] switch routes enforcement: per-action cap on the
  // legacy path, install-time consent on the family path.
  @override
  bool get requiresStepUp => true;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final r = await _bridge.longPress(
      displayId: call.params['displayId']! as int,
      x: (call.params['x']! as num).toDouble(),
      y: (call.params['y']! as num).toDouble(),
      durationMs: call.params['durationMs']! as int,
    );
    return r.toJson();
  }
}
