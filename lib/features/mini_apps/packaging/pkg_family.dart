/// `pkg` family — read installed packages, foreground app, usage
/// stats, and launch a target package on a chosen display.
///
/// Permissions:
///   * `pkg.read`         (tier-1): list / foreground / usage
///   * `pkg.launch`       (tier-2): launch / move on `ivi` or
///                         `passenger` displays
///   * `pkg.launch.cluster` (tier-3): launch_cluster / move_cluster
///                         on `cluster` displays (driver-instrument
///                         virtual surfaces — the BYD XDJA family).
///                         Separate permission so a manifest must
///                         opt in explicitly; declined-by-default
///                         keeps the driver eyeline safe.
///
/// Handlers:
///   * `pkg.list({includeSystem?})` — installed packages, label,
///     versionName, versionCode, isSystem, optional iconHash.
///   * `pkg.foreground()` — current foreground package.
///   * `pkg.usage({windowMs})` — UsageStatsManager rows over a
///     window (capped server-side at 24 h).
///   * `pkg.launch({packageName, displayId?})` — launch on `ivi`
///     or `passenger`. Cluster targets are rejected with
///     `role:requires_cluster_op`; caller must use `launch_cluster`.
///   * `pkg.launch_cluster({packageName, displayId})` — launch on
///     a `cluster` display. Tier-3 permission, never offered in a
///     secondary surface.
///   * `pkg.move({packageName, displayId})` — same role split as
///     launch.
///   * `pkg.move_cluster({packageName, displayId})` — same role
///     split as launch_cluster.
///
/// `secondaryAllowed` is **false** for the launch / move handlers
/// — a secondary surface launching apps is an escalation gadget.
/// The read-only handlers ARE allowed in the secondary context,
/// so a cluster widget can render a "now playing on IVI" pill.
library;

import '../../admin_mini_apps/domain/admin_op.dart'
    show EnumParamRule, IntParamRule, ParamRule, RegexParamRule;
import '../bridge/mini_app_family.dart';
import 'pkg_native_bridge.dart';

class PkgFamily extends MiniAppFamily {
  PkgFamily({PkgNativeBridge? bridge})
    : _bridge = bridge ?? PlatformPkgNativeBridge();

  final PkgNativeBridge _bridge;

  @override
  String get familyId => 'pkg';

  /// Union of every permission this family draws on. The gate
  /// consults [permissionIdFor] per-handler to map op → permission,
  /// so this set just needs to enumerate everything that appears
  /// downstream.
  @override
  Set<String> get permissionIds => const {
    'pkg.read',
    'pkg.launch',
    'pkg.launch.cluster',
  };

  /// Per-op override — read handlers map to `pkg.read`; standard
  /// launch + move + stop map to `pkg.launch`; their `_cluster`
  /// siblings map to `pkg.launch.cluster`. Without this override
  /// every handler would require all three permissions, which would
  /// force every read mini-app to also request launch.
  @override
  String permissionIdFor(String op) {
    switch (op) {
      case 'launch':
      case 'move':
      case 'stop':
        return 'pkg.launch';
      case 'launch_cluster':
      case 'move_cluster':
        return 'pkg.launch.cluster';
      case 'list':
      case 'foreground':
      case 'usage':
      case 'icon':
        return 'pkg.read';
    }
    // Future ops default to the read tier — safer fallback. The
    // launch / move handlers are the only ones that should ever
    // map to the write permission, and their case branches above
    // are explicit.
    return 'pkg.read';
  }

  /// Read-only handlers stay safe in a secondary surface (no state
  /// mutation, no launch). Every launch / move / stop variant —
  /// standard or cluster — stays off secondary surfaces.
  @override
  bool get secondaryAllowed => true;

  @override
  bool secondaryAllowedFor(String op) =>
      op != 'launch' &&
      op != 'move' &&
      op != 'stop' &&
      op != 'launch_cluster' &&
      op != 'move_cluster';

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'list': _ListHandler(_bridge),
    'foreground': _ForegroundHandler(_bridge),
    'usage': _UsageHandler(_bridge),
    'launch': _LaunchHandler(_bridge),
    'move': _MoveHandler(_bridge),
    'stop': _StopHandler(_bridge),
    'launch_cluster': _LaunchClusterHandler(_bridge),
    'move_cluster': _MoveClusterHandler(_bridge),
    'icon': _IconHandler(_bridge),
  };
}

class _ListHandler implements FamilyHandler {
  _ListHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    // Boolean slot via EnumParamRule. The validator's strict
    // unknown-slots check rejects any param the SDK sends that
    // isn't declared here, so includeSystem must be in the schema
    // even though it's optional from the SDK's perspective.
    'includeSystem': const EnumParamRule(values: [true, false]),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final includeSystem = call.params['includeSystem'] as bool? ?? false;
    final packages = await _bridge.list(includeSystem: includeSystem);
    return <String, Object?>{
      'packages': packages.map((p) => p.toJson()).toList(),
    };
  }
}

class _ForegroundHandler implements FamilyHandler {
  _ForegroundHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{};

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final fg = await _bridge.foreground();
    if (fg == null) {
      // Don't throw — the canonical empty response lets the SDK
      // surface "no foreground info available" without a typed
      // error envelope. Permission missing is the most common
      // cause; that's a config issue, not a programming bug.
      return <String, Object?>{'packageName': null};
    }
    return fg.toJson();
  }
}

class _UsageHandler implements FamilyHandler {
  _UsageHandler(this._bridge);
  final PkgNativeBridge _bridge;

  /// Window cap: 24 hours. Wider windows are rarely useful for
  /// in-car launchers and they make the per-package totals less
  /// meaningful (a phone-paired 30-day window dominates the rows).
  static const int _maxWindowMs = 24 * 60 * 60 * 1000;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{
    'windowMs': IntParamRule(min: 1000, max: _maxWindowMs),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final windowMs = call.params['windowMs']! as int;
    final rows = await _bridge.usage(windowMs: windowMs);
    return <String, Object?>{
      'rows': rows.map((r) => r.toJson()).toList(),
      'windowMs': windowMs,
    };
  }
}

class _LaunchHandler implements FamilyHandler {
  _LaunchHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    // packageName is required — Android validates the shape too,
    // but failing here gives a typed pkg_invalid before the
    // MethodChannel hop.
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    // displayId is optional from the SDK's perspective; -1 is the
    // sentinel for "use the default display" (host falls through to
    // Context.startActivity instead of am-start).
    'displayId': const IntParamRule(min: -1, max: 1024, defaultValue: -1),
    // Optional role hint. Lets the host pick the right transport when
    // the trim has no addressable Display for the requested role —
    // today the only case is `passenger` on Di5.0 (L5 / L5U) where
    // DiShare's mirror chain replaces `am start --display N`. Empty
    // string is the "no hint" default; the EnumParamRule rejects any
    // other value so the wire shape stays closed.
    'targetRole': const EnumParamRule(
      values: ['', 'passenger'],
      defaultValue: '',
    ),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName'] as String?;
    if (packageName == null || packageName.isEmpty) {
      throw const BridgeOpError(
        code: 'pkg_invalid',
        message: 'packageName is required',
      );
    }
    // Cheap path-traversal / injection guard. PackageManager itself
    // rejects malformed names, but failing here gives a typed
    // error instead of an opaque native exception.
    if (!_packageNamePattern.hasMatch(packageName)) {
      throw const BridgeOpError(
        code: 'pkg_invalid',
        message: 'packageName must match ^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)+\$',
      );
    }
    // -1 sentinel from validated params means "default display" —
    // the bridge contract uses null for that (Kotlin side falls
    // through to Context.startActivity instead of am-start).
    final raw = call.params['displayId'] as int?;
    final displayId = (raw == null || raw < 0) ? null : raw;
    final roleParam = call.params['targetRole'] as String?;
    final targetRole = (roleParam == null || roleParam.isEmpty)
        ? null
        : roleParam;
    try {
      final r = await _bridge.launch(
        packageName: packageName,
        displayId: displayId,
        targetRole: targetRole,
      );
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(code: 'pkg_launch_failed', message: e.toString());
    }
  }

  /// Permissive Android package-name pattern. The native side
  /// validates again — this is a fast-fail at the bridge boundary.
  static final _packageNamePattern = RegExp(
    r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$',
  );
}

class _MoveHandler implements FamilyHandler {
  _MoveHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    // Required (no default) — moving to "default display" is just
    // displayId=0; pkg.launch is the right op for that case.
    'displayId': const IntParamRule(min: 0, max: 1024),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName']! as String;
    final displayId = call.params['displayId']! as int;
    try {
      final r = await _bridge.move(
        packageName: packageName,
        displayId: displayId,
      );
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(code: 'pkg_move_failed', message: e.toString());
    }
  }
}

class _StopHandler implements FamilyHandler {
  _StopHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName']! as String;
    try {
      final r = await _bridge.stop(packageName: packageName);
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(code: 'pkg_stop_failed', message: e.toString());
    }
  }
}

/// Cluster-targeted launch. Same wire shape as [_LaunchHandler] but
/// the bridge hop signals `expectCluster: true` so the native role
/// check rejects ivi/passenger/unknown displays. Permission gating
/// is handled by the family's [PkgFamily.permissionIdFor] mapping
/// this op to `pkg.launch.cluster`.
class _LaunchClusterHandler implements FamilyHandler {
  _LaunchClusterHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    // No -1 sentinel here — cluster targets are never the default
    // display, so the schema requires an explicit displayId chosen
    // from the `role == 'cluster'` entries in `display.list()`.
    'displayId': const IntParamRule(min: 0, max: 1024),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName']! as String;
    final displayId = call.params['displayId']! as int;
    try {
      final r = await _bridge.launchCluster(
        packageName: packageName,
        displayId: displayId,
      );
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(
        code: 'pkg_launch_cluster_failed',
        message: e.toString(),
      );
    }
  }
}

/// Phase D: launcher-icon delivery. Read-only — same permission
/// tier as `list` / `foreground` / `usage`. The host renders the
/// icon to a 96 px PNG and returns base64 bytes; mini-apps key their
/// dataUrl cache by the iconHash supplied in `pkg.list`.
class _IconHandler implements FamilyHandler {
  _IconHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    // Same package-name pattern as the launch / move / stop handlers
    // so a malformed name fails at the bridge boundary instead of
    // travelling all the way down to PackageManager.
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName']! as String;
    try {
      final r = await _bridge.icon(packageName: packageName);
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(code: 'pkg_icon_failed', message: e.toString());
    }
  }
}

/// Cluster-targeted move. Same shape as [_MoveHandler] with the
/// `expectCluster: true` bridge contract so non-cluster targets are
/// rejected before the am-stack-move-task path runs.
class _MoveClusterHandler implements FamilyHandler {
  _MoveClusterHandler(this._bridge);
  final PkgNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    'displayId': const IntParamRule(min: 0, max: 1024),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final packageName = call.params['packageName']! as String;
    final displayId = call.params['displayId']! as int;
    try {
      final r = await _bridge.moveCluster(
        packageName: packageName,
        displayId: displayId,
      );
      return r.toJson();
    } on Exception catch (e) {
      throw BridgeOpError(
        code: 'pkg_move_cluster_failed',
        message: e.toString(),
      );
    }
  }
}
