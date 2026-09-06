/// `surface` family — opens a top-level rendering surface on a target
/// display for a mini-app to draw on. Tier-2 (`surface.write`).
///
/// Handlers:
///   * `surface.create({displayId, route?})` — opens a Presentation /
///     overlay on the target display. Returns
///     `{surfaceId, path, displayId, route}`.
///   * `surface.navigate({surfaceId, route})` — change route within
///     the surface.
///   * `surface.destroy({surfaceId})` — tear down.
///   * `surface.list()` — enumerate active surfaces.
///
/// `secondaryAllowed` is **false**: a mini-app rendered on a
/// secondary surface cannot itself open more surfaces. That would be
/// a recursive privilege escalation — every gate the family enforces
/// is bypassable if a child can call back into the family.
library;

import '../../admin_mini_apps/domain/admin_op.dart'
    show IntParamRule, ParamRule, RegexParamRule;
import '../bridge/mini_app_family.dart';
import 'surface_native_bridge.dart';

/// Resolves an `appId` to its installed bundle's `index.html`
/// `file://` URI. Wired by `family_executor_provider.dart` against
/// `installedMiniAppStoreProvider.indexHtmlPath`. Tests inject a
/// closure that returns a fixed string.
///
/// Returns `null` when the app isn't installed locally — `_CreateHandler`
/// surfaces that as a `surface_denied` envelope so the SDK gets a
/// typed error instead of a stuck WebView.
typedef BundleUriResolver = Future<String?> Function(String appId);

class SurfaceFamily extends MiniAppFamily {
  SurfaceFamily({
    SurfaceNativeBridge? bridge,
    BundleUriResolver? bundleUriResolver,
  }) : _bridge = bridge ?? PlatformSurfaceNativeBridge(),
       _bundleUriResolver = bundleUriResolver ?? _missingResolver;

  final SurfaceNativeBridge _bridge;
  final BundleUriResolver _bundleUriResolver;

  static Future<String?> _missingResolver(String appId) async {
    // Default for tests / hosts that haven't wired the resolver.
    // Production wires the real resolver in
    // `family_executor_provider.dart`. Returning null here lets
    // the create handler emit a clean `surface_denied` envelope.
    return null;
  }

  @override
  String get familyId => 'surface';

  @override
  Set<String> get permissionIds => const {'surface.write'};

  @override
  bool get secondaryAllowed => false;

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'create': _CreateHandler(_bridge, _bundleUriResolver),
    'navigate': _NavigateHandler(_bridge),
    'destroy': _DestroyHandler(_bridge),
    'list': _ListHandler(_bridge),
  };
}

class _CreateHandler implements FamilyHandler {
  _CreateHandler(this._bridge, this._resolveBundleUri);
  final SurfaceNativeBridge _bridge;
  final BundleUriResolver _resolveBundleUri;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'displayId': const IntParamRule(min: 0, max: 1024),
    // Path + optional query string. Path stays tight (no scheme jumps,
    // no `..` traversal — only word chars, dots, dashes, slashes).
    // Query allows the URL-safe set so mini-apps can pass small
    // parameters (e.g. `?preset=nebula`, `?grad=<url-encoded css>`).
    'route': RegexParamRule(
      pattern: r'^/[A-Za-z0-9._\-/]*(\?[A-Za-z0-9._\-/=&%~+,:;*!#]*)?$',
    ),
  };
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final displayId = call.params['displayId']! as int;
    final route = call.params['route'] as String?;
    final appId = call.session.appId;
    final bundleUri = await _resolveBundleUri(appId);
    if (bundleUri == null || bundleUri.isEmpty) {
      // App isn't installed locally (or its bundle was wiped). Fail
      // fast with the canonical surface_denied code — no native call.
      throw const BridgeOpError(
        code: 'surface_denied',
        message: 'mini-app bundle not installed locally',
      );
    }
    final fileUri = bundleUri.startsWith('file://')
        ? bundleUri
        : Uri.file(bundleUri).toString();
    try {
      final r = await _bridge.create(
        displayId: displayId,
        appId: appId,
        bundleUri: fileUri,
        route: route,
      );
      return r.toJson();
    } on Exception catch (e) {
      // Surface platform errors as the canonical surface_denied code
      // so the SDK's typed controller can render a clean message.
      throw BridgeOpError(code: 'surface_denied', message: e.toString());
    }
  }
}

class _NavigateHandler implements FamilyHandler {
  _NavigateHandler(this._bridge);
  final SurfaceNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'surfaceId': RegexParamRule(pattern: r'^sfc_[0-9a-fA-F\-]+$'),
    'route': RegexParamRule(
      pattern: r'^/[A-Za-z0-9._\-/]*(\?[A-Za-z0-9._\-/=&%~+,:;*!#]*)?$',
    ),
  };
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final surfaceId = call.params['surfaceId']! as String;
    final route = call.params['route'] as String?;
    try {
      await _bridge.navigate(surfaceId: surfaceId, route: route);
      return {'ok': true};
    } on Exception catch (e) {
      throw BridgeOpError(code: 'surface_not_found', message: e.toString());
    }
  }
}

class _DestroyHandler implements FamilyHandler {
  _DestroyHandler(this._bridge);
  final SurfaceNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'surfaceId': RegexParamRule(pattern: r'^sfc_[0-9a-fA-F\-]+$'),
  };
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final surfaceId = call.params['surfaceId']! as String;
    try {
      await _bridge.destroy(surfaceId: surfaceId);
      return {'ok': true};
    } on Exception catch (e) {
      throw BridgeOpError(code: 'surface_not_found', message: e.toString());
    }
  }
}

class _ListHandler implements FamilyHandler {
  _ListHandler(this._bridge);
  final SurfaceNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const {};
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final surfaces = await _bridge.list();
    return <String, Object?>{
      'surfaces': surfaces.map((s) => s.toJson()).toList(growable: false),
    };
  }
}
