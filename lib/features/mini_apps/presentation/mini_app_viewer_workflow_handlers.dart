part of 'mini_app_viewer.dart';

/// Workflow-canvas + voice bridge handlers, split out of [_MiniAppViewerState]
/// to keep the viewer under the maintainability LOC ratchet. This is a `part`
/// of the same library, so the extension keeps full access to the viewer's
/// private state ([_payload], [_carBridge], [ref]) — no behaviour change, pure
/// relocation of the `workflow.*` / `voice.status` registrations and their two
/// non-trivial callbacks.
extension _WorkflowBridgeHandlers on _MiniAppViewerState {
  /// Registers the `workflow.*` CRUD/template/test handlers plus `voice.status`.
  /// Called once from [_registerHandlers].
  void _registerWorkflowHandlers(InAppWebViewController controller) {
    // ── workflow.* ────────────────────────────────────────────────
    // workflow.catalog: the authorable ACTION palette (the command
    // registry + safety flags). car.list returns readable signals
    // only, so this is the action source for the workflow canvas.
    // Tier-1 read-only, same surface class as car.list.
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.catalog',
      callback: _handleWorkflowCatalog,
    );
    // workflow CRUD — host-proxied to the authenticated backend (a
    // mini-app can't call the per-user API directly; the car is logged
    // in as the user). The authoring canvas persists through these.
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.list',
      callback: (args) => ref.read(workflowBridgeServiceProvider).list(),
    );
    // workflow.test — one-shot DRAFT run for the canvas "Test" button.
    // Compiles the in-progress document and runs it once through the real
    // engine action path (executes notify/app/car-command with the live
    // safety gates), WITHOUT saving or arming it.
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.test',
      callback: _handleWorkflowTest,
    );
    // voice.status: lets the canvas warn that a "When I say…" automation
    // won't fire hands-free unless the voice assistant / wake word is on.
    _registerScopedHandler(
      controller,
      handlerName: 'voice.status',
      callback: (args) {
        final s = ref.read(settingsProvider).value;
        return <String, Object?>{
          'wakeWordEnabled': s?.wakeWordEnabled ?? false,
          'assistantEnabled': s?.voiceAssistantEnabled ?? false,
        };
      },
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.save',
      callback: (args) =>
          ref.read(workflowBridgeServiceProvider).save(_payload(args)),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.setEnabled',
      callback: (args) =>
          ref.read(workflowBridgeServiceProvider).setEnabled(_payload(args)),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.delete',
      callback: (args) =>
          ref.read(workflowBridgeServiceProvider).remove(_payload(args)),
    );
    // workflow templates — the sharing lane (browse / publish / import),
    // all host-proxied to the authenticated backend like the CRUD above.
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.templates',
      callback: (args) =>
          ref.read(workflowBridgeServiceProvider).templates(_payload(args)),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.myTemplates',
      callback: (args) => ref.read(workflowBridgeServiceProvider).myTemplates(),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.getTemplate',
      callback: (args) =>
          ref.read(workflowBridgeServiceProvider).getTemplate(_payload(args)),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.publishTemplate',
      callback: (args) => ref
          .read(workflowBridgeServiceProvider)
          .publishTemplate(_payload(args)),
    );
    _registerScopedHandler(
      controller,
      handlerName: 'workflow.importTemplate',
      callback: (args) => ref
          .read(workflowBridgeServiceProvider)
          .importTemplate(_payload(args)),
    );
  }

  Future<Map<String, Object?>> _handleWorkflowTest(List<dynamic> args) async {
    final doc = _payload(args)['document'];
    if (doc is! Map) {
      return <String, Object?>{'ok': false, 'error': 'no document'};
    }
    final compiled = compileWorkflowDocument(doc.cast<String, Object?>());
    if (!compiled.ok || compiled.workflow == null) {
      return <String, Object?>{
        'ok': false,
        'error': compiled.error ?? 'this workflow can’t run yet',
      };
    }
    return ref.read(workflowEngineProvider).testRun(compiled.workflow!);
  }

  Future<Map<String, Object?>> _handleWorkflowCatalog(
    List<dynamic> args,
  ) async {
    final catalog = _carBridge.workflowCatalog();
    // Enrich with the device's launchable apps so the canvas's app.* action
    // picker lists what's actually installed on THIS car (no hardcoded
    // guesses). Each entry is {package, label}; the canvas stores the
    // package as the action arg and the engine launches it by package.
    // Best-effort — on any failure we omit `apps` and the canvas falls
    // back to free-text entry.
    try {
      // includeSystem: true → also list built-in launchable apps (Maps,
      // media). The native side already filters to the LAUNCHER subset
      // (queryIntentActivities), so this stays "apps with an icon", never
      // hundreds of background services.
      final apps = await PlatformPkgNativeBridge().list(includeSystem: true);
      catalog['apps'] =
          <Map<String, Object?>>[
            for (final a in apps)
              if (a.packageName != _kWorkflowHostPackage &&
                  a.label.trim().isNotEmpty)
                {'package': a.packageName, 'label': a.label},
          ]..sort(
            (x, y) => (x['label']! as String).toLowerCase().compareTo(
              (y['label']! as String).toLowerCase(),
            ),
          );
    } catch (_) {
      // Leave `apps` off — the canvas degrades to a free-text app field.
    }
    return catalog;
  }
}
