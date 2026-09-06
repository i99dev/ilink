part of 'mini_app_viewer.dart';

/// Local scope checks and the capability list share one viewer-bound identity.
extension _LocalPermissionHandlers on _MiniAppViewerState {
  Future<bool> _hasScope(String scope) => ref
      .read(localMiniAppGrantsProvider)
      .allows(widget.app.id, widget.app.bundleSha256, scope);

  void _registerScopedHandler(
    InAppWebViewController controller, {
    required String handlerName,
    required FutureOr<dynamic> Function(List<dynamic>) callback,
  }) {
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (args) async {
        final scope = directBridgeScope(handlerName);
        if (_disposed || scope == null || !await _hasScope(scope)) {
          return {
            'success': false,
            'ok': false,
            'error': {
              'code': 'permission_denied',
              'message': 'Local permission required: $scope',
            },
          };
        }
        final result = await callback(args);
        if (_disposed || !await _hasScope(scope)) {
          return _MiniAppViewerState._error(
            'permission_denied',
            'Permission was revoked',
          );
        }
        return result;
      },
    );
  }

  Future<Map<String, dynamic>> _handleCapabilities(List<dynamic> args) async {
    final registry = ref.read(bridgeFamilyRegistryProvider);
    final handlers = <String>['getContext', 'capabilities'];
    for (final name in const [
      'car.list',
      'car.read',
      'car.subscribe',
      'car.unsubscribe',
      'car.command',
      'car.identity',
      'car.asset',
      'car.connection.subscribe',
      'car.connection.unsubscribe',
      'location.read',
      'workflow.catalog',
      'workflow.list',
      'workflow.save',
      'workflow.setEnabled',
      'workflow.delete',
      'workflow.templates',
      'workflow.myTemplates',
      'workflow.getTemplate',
      'workflow.publishTemplate',
      'workflow.importTemplate',
      'workflow.test',
      'voice.status',
    ]) {
      if (await _hasScope(directBridgeScope(name)!)) handlers.add(name);
    }
    for (final family in registry.families) {
      for (final op in family.handlers.keys) {
        if (await _hasScope(family.permissionIdFor(op))) {
          handlers.add('${family.familyId}.$op');
        }
      }
    }
    return {
      'bridgeVersion': CarBridgeService.kBridgeVersion,
      'handlers': handlers,
    };
  }
}
