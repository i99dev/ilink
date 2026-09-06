library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_navigator.dart';
import '../../../platform/location/location_service.dart';
import '../../../sdk/car/client.dart';
import '../../apps/app_voice_dispatch.dart';
import '../../mini_apps/runtime/display_native_bridge.dart';
import '../../mini_apps/runtime/surface_native_bridge.dart';
import '../../radio/providers.dart';
import '../../radio/radio_voice_dispatch.dart';
import '../../voice/data/voice_service_bridge.dart';
import '../../../kernel/shell/shell_tool_bridge_provider.dart';
import 'cluster_render_service.dart';
import 'compiled_workflow.dart';
import 'workflow_engine.dart';
import 'workflow_notify_service.dart';

/// Speed signal the cluster persistent-render gate reads.
const String _kSpeedSignal = 'Statistic.STATISTIC_SPEED_SIG_VDIS';

class EnabledWorkflows extends Notifier<List<CompiledWorkflow>> {
  @override
  List<CompiledWorkflow> build() => const <CompiledWorkflow>[];

  /// Replace the active set (the store / sync layer calls this).
  void set(List<CompiledWorkflow> workflows) => state = workflows;
}

final enabledWorkflowsProvider =
    NotifierProvider<EnabledWorkflows, List<CompiledWorkflow>>(
      EnabledWorkflows.new,
    );

/// The distinct normalized phrases of every armed `voice.phrase` workflow —
/// derived from [enabledWorkflowsProvider], the SINGLE source. The on-device
/// recognizer watches this to inject these phrases into the Vosk grammar
/// (so they're heard) and re-applies the grammar when the set changes, so a
/// newly-saved voice automation is recognized without toggling voice.
final activeVoicePhrasesProvider = Provider<Set<String>>((ref) {
  final workflows = ref.watch(enabledWorkflowsProvider);
  return {
    for (final wf in workflows)
      if (wf.trigger is VoiceTrigger) ...(wf.trigger as VoiceTrigger).phrases,
  };
});

/// The long-lived engine. `keepAlive` so it outlives every screen and
/// keeps firing with the canvas closed (it rides the existing
/// keep-alive ForegroundService for liveness — see the plan §6.4).
final workflowEngineProvider = Provider<WorkflowEngine>((ref) {
  // Cluster renderer — one instance (owns the persistent surface +
  // transient timers). Goes through the host surface.* family only.
  final clusterRender = ClusterRenderService(
    surface: PlatformSurfaceNativeBridge(),
    resolveClusterDisplayId: () async {
      final displays = await PlatformDisplayNativeBridge().list();
      final cluster =
          displays
              .where((d) => d.role == 'cluster' && d.clusterAvailable)
              .firstOrNull ??
          displays.where((d) => d.isCluster).firstOrNull;
      return cluster?.id;
    },
    // TODO(on-car): resolve the installed wf-cluster-render bundle
    // (appId + local index path). Until that bundle ships, cluster output
    // gracefully skips with a 'no_cluster_bundle' log.
    resolveClusterApp: () async => null,
    readSpeed: () async => ref.read(carClientProvider).value(_kSpeedSignal),
  );
  ref.onDispose(clusterRender.dispose);

  final notifyService = WorkflowNotifyService(
    showInApp: (title, body) {
      final messenger = appScaffoldMessengerKey.currentState;
      if (messenger == null) return false;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              body == null || body.isEmpty ? title : '$title\n$body',
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return true;
    },
    showSystem: (text) =>
        ref.read(voiceServiceBridgeProvider).setNotificationText(text),
  );

  final engine = WorkflowEngine(
    dispatchCluster: (route, args) => clusterRender.render(route, args),
    dispatchNotify: notifyService.notify,
    // radio/app actions route to their subsystems (read per-call so the
    // engine never caches a controller — same lifecycle discipline as
    // the CarClient rebind).
    dispatchRadio: (actionId, args) async {
      final out = await dispatchRadioCommand(
        ref.read(radioControllerProvider.notifier),
        actionId,
        args,
      );
      return out.cast<String, Object?>();
    },
    dispatchApp: (actionId, args) async {
      final out = await dispatchAppCommand(
        ref.read(shellOpsCoordinatorProvider),
        actionId,
        args,
      );
      return out.cast<String, Object?>();
    },
  );

  // Re-bind on every CarClient identity change. `fireImmediately` does
  // the initial bind. carClientProvider returns a NEW BydClient on each
  // brand re-resolve, so this — NOT a one-time capture — is what keeps
  // the engine alive across a re-detect.
  ref.listen<CarClient>(
    carClientProvider,
    (_, next) => engine.bindClient(next),
    fireImmediately: true,
  );

  // React to the active workflow set.
  ref.listen<List<CompiledWorkflow>>(
    enabledWorkflowsProvider,
    (_, workflows) => engine.loadWorkflows(workflows),
    fireImmediately: true,
  );

  // Feed GPS fixes to geofence triggers. Reuses the host's proven custom
  // GNSS stream (currentLocationProvider); the engine no-ops when no geo
  // workflow is armed, so this costs only what location_service already runs.
  ref.listen(currentLocationProvider, (_, next) {
    final fix = next.value;
    if (fix != null) engine.onLocation(fix.latitude, fix.longitude);
  });

  ref.onDispose(engine.dispose);
  ref.keepAlive();
  return engine;
});
