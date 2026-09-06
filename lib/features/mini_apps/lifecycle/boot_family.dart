/// `boot` family — declare which packages auto-launch on cold-start.
///
/// Tier-2 (`boot.write`). Three handlers:
///   * `boot.set({packageName, displayId?, route?})` — insert/replace
///     one declaration. Returns the persisted row.
///   * `boot.list()` — every declaration this mini-app owns under
///     the active (user, deviceId). Cross-mini-app listing is deliberately
///     not exposed — a mini-app shouldn't know what others do at boot.
///   * `boot.unset({packageName})` — delete one declaration.
///
/// `secondaryAllowed` is **false**: a child surface declaring boot
/// apps would let any cluster widget hijack the next cold-start.
library;

import '../../admin_mini_apps/domain/admin_op.dart'
    show IntParamRule, ParamRule, RegexParamRule;
import '../bridge/mini_app_family.dart';
import 'boot_store.dart';

/// Lazy [BootStore] resolver. Lets [BootFamily] register
/// synchronously at host bootstrap even though the admin DB opens
/// asynchronously inside `adminDatabaseProvider`. Each handler
/// awaits the future on invocation; the provider caches the
/// underlying DB so the await is effectively free after the first
/// call.
typedef BootStoreResolver = Future<BootStore> Function();

class BootFamily extends MiniAppFamily {
  BootFamily({required BootStoreResolver storeResolver})
    : _resolver = storeResolver;

  /// Convenience constructor for tests — wraps a pre-built store in
  /// a one-shot resolver.
  BootFamily.withStore(BootStore store) : _resolver = (() async => store);

  final BootStoreResolver _resolver;

  @override
  String get familyId => 'boot';

  @override
  Set<String> get permissionIds => const {'boot.write'};

  @override
  bool get secondaryAllowed => false;

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'set': _SetHandler(_resolver),
    'list': _ListHandler(_resolver),
    'unset': _UnsetHandler(_resolver),
  };
}

class _SetHandler implements FamilyHandler {
  _SetHandler(this._store);
  final BootStoreResolver _store;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
    // -1 sentinel = default display. The pkg launcher resolves -1 to
    // Context.startActivity (no `--display` flag) which lands on the
    // default display.
    'displayId': const IntParamRule(min: -1, max: 1024, defaultValue: -1),
    // Optional intent-extras passthrough. Empty string is the
    // sentinel for "no route" — host stores null in that case.
    'route': RegexParamRule(pattern: r'^.*$', defaultValue: ''),
  };

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    // Schema validates these slots before execute runs in the live
    // path; the manual re-check is belt-and-suspenders for direct
    // handler invocations (unit tests, future replay paths).
    final packageName = call.params['packageName'] as String?;
    if (packageName == null || packageName.isEmpty) {
      throw const BridgeOpError(
        code: 'boot_invalid',
        message: 'packageName is required',
      );
    }
    if (!_packageNamePattern.hasMatch(packageName)) {
      throw const BridgeOpError(
        code: 'boot_invalid',
        message: 'packageName must match ^[a-z][a-z0-9_]*(\\.[a-z0-9_]+)+\$',
      );
    }
    final displayId = (call.params['displayId'] as int?) ?? -1;
    final rawRoute = call.params['route'] as String?;
    // Empty string is the sentinel default — store null so the
    // BootEntry's `route` field reflects "unset".
    final route = (rawRoute == null || rawRoute.isEmpty) ? null : rawRoute;

    final store = await _store();
    final entry = await store.set(
      userId: call.session.userId,
      deviceId: call.session.deviceId,
      appId: call.session.appId,
      packageName: packageName,
      displayId: displayId,
      route: route,
    );
    return entry.toJson();
  }

  static final _packageNamePattern = RegExp(
    r'^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$',
  );
}

class _ListHandler implements FamilyHandler {
  _ListHandler(this._store);
  final BootStoreResolver _store;

  @override
  Map<String, ParamRule> get paramSchema => const <String, ParamRule>{};

  @override
  bool get requiresStepUp => false;

  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final store = await _store();
    final entries = await store.listForApp(
      userId: call.session.userId,
      deviceId: call.session.deviceId,
      appId: call.session.appId,
    );
    return <String, Object?>{
      'entries': entries.map((e) => e.toJson()).toList(),
    };
  }
}

class _UnsetHandler implements FamilyHandler {
  _UnsetHandler(this._store);
  final BootStoreResolver _store;

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
    final packageName = call.params['packageName'] as String?;
    if (packageName == null || packageName.isEmpty) {
      throw const BridgeOpError(
        code: 'boot_invalid',
        message: 'packageName is required',
      );
    }
    final store = await _store();
    final removed = await store.unset(
      userId: call.session.userId,
      deviceId: call.session.deviceId,
      appId: call.session.appId,
      packageName: packageName,
    );
    return <String, Object?>{'removed': removed};
  }
}
