/// `cursor` family — IVI-side touchpad-style cursor for "remote
/// control of cluster" mini-apps.
///
/// Mode: a SYSTEM_ALERT_WINDOW view drawn on the IVI as a pointer.
/// The mini-app captures touch events, translates IVI coords →
/// cluster coords, calls `cursor.move` for visual feedback, and on
/// release calls [GestureFamily]'s `gesture.tap` to land the actual
/// tap on the cluster. NOT drawn on the cluster — the XDJA composer
/// signature-gates frame delivery there.
///
/// Same pattern i99dev's `CursorOverlayManager` ships in. Hot-path
/// bypass on `cursor.move` because a 60 Hz drag would otherwise
/// burn the gate per frame.
///
/// Pure-Dart class — no platform imports. The `*NativeBridge`
/// abstraction is the only seam to native code.
library;

import '../../admin_mini_apps/domain/admin_op.dart'
    show EnumParamRule, IntParamRule, NumberParamRule, ParamRule;
import '../bridge/mini_app_family.dart';
import 'cursor_native_bridge.dart';

class CursorFamily extends MiniAppFamily {
  CursorFamily({CursorNativeBridge? bridge})
    : _bridge = bridge ?? PlatformCursorNativeBridge();

  final CursorNativeBridge _bridge;

  @override
  String get familyId => 'cursor';

  @override
  Set<String> get permissionIds => const {'cursor.write'};

  // Privileged — must NOT be exposed to a secondary surface (a child
  // surface that could draw cursors above the IVI would be a
  // confusion-attack gadget).
  @override
  bool get secondaryAllowed => false;

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'attach': _AttachHandler(_bridge),
    'detach': _DetachHandler(_bridge),
    'move': _MoveHandler(_bridge),
    'style': _StyleHandler(_bridge),
  };
}

const _displayId = IntParamRule(min: 0, max: 100);
// JS numbers cross the bridge as doubles — accept num so cursor.move
// from `client.cursor.move(x, y)` doesn't reject on every drag frame.
const _coord = NumberParamRule(min: -1, max: 10_000);
const _style = EnumParamRule(values: <String>['dot', 'glow', 'ring']);

class _AttachHandler implements FamilyHandler {
  _AttachHandler(this._bridge);
  final CursorNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'targetDisplayId': _displayId,
    'style': _style,
  };

  @override
  bool get requiresStepUp => false;

  // Standard cadence — full gate at attach. Subsequent `move` calls
  // run under the hot-path bypass and skip the gate.
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final ok = await _bridge.attach(
      targetDisplayId: call.params['targetDisplayId']! as int,
      style: call.params['style']! as String,
    );
    return <String, Object?>{'ok': ok};
  }
}

class _DetachHandler implements FamilyHandler {
  _DetachHandler(this._bridge);
  final CursorNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const {};

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    await _bridge.detach();
    return const <String, Object?>{'ok': true};
  }
}

class _MoveHandler implements FamilyHandler {
  _MoveHandler(this._bridge);
  final CursorNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'x': _coord,
    'y': _coord,
  };

  @override
  bool get requiresStepUp => false;

  // Hot-path: bypassed by FamilyExecutor for 5s after attach. A drag
  // generates ~60 events per second — gating each one would burn the
  // cap store with ~60 reads per second per active drag.
  @override
  HandlerCadence get cadence => HandlerCadence.hot;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    await _bridge.move(
      x: (call.params['x']! as num).toDouble(),
      y: (call.params['y']! as num).toDouble(),
    );
    return const <String, Object?>{'ok': true};
  }
}

class _StyleHandler implements FamilyHandler {
  _StyleHandler(this._bridge);
  final CursorNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'style': _style,
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    await _bridge.style(call.params['style']! as String);
    return const <String, Object?>{'ok': true};
  }
}
