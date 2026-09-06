import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/_car_domain/command/registry.dart';
import '../../features/_car_domain/safety/security_bridge.dart';
import '../../features/mini_apps/bridge/bridge_family_registration.dart';
import '../../features/mini_apps/lifecycle/boot_launcher_provider.dart';
import '../../features/workflow/engine/workflow_engine_provider.dart';
import '../../features/workflow/data/workflow_providers.dart';
import '../../sdk/brands/byd/identity/byd_model_detector.dart';
import '../../sdk/car/client.dart';
import '../../kernel/logging/logger.dart';
import '../update/update_controller.dart';
import '../update/update_orchestrator.dart';
import 'app_listeners.dart';

/// Device-only boot. External integrations are never registered implicitly.
class BootSequence {
  BootSequence(this._ref);
  final WidgetRef _ref;
  bool _started = false;
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _ref.read(bootReplayProvider);
    _ref.read(bootWipeResumeProvider);
    _ref.read(installedVersionCodeProvider);
    _ref.read(modelDetectorProvider);
    setupBridgeRegistry(_ref);
    _ref.read(workflowEngineProvider);
    _ref.listenManual(localWorkflowRegistrationProvider, (_, _) {});
    unawaited(
      _ref
          .read(carClientProvider)
          .liveFeatures()
          .catchError((Object _) => <String, int>{}),
    );
    unawaited(_warnOnCommandDrift());
    // Registers consent-driven discovery; no network request while Updates is off.
    _ref.listenManual(updateOrchestratorProvider, (_, _) {});
  }

  Future<void> _warnOnCommandDrift() async {
    const log = Logger('CommandDrift');
    try {
      // Wait for the local native table reader during cold startup.
      var known = <String>{};
      for (var attempt = 1; attempt <= 10; attempt++) {
        known = (await _ref.read(carClientProvider).knownActions()).toSet();
        if (known.isNotEmpty) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      otaDiagLog('cmd.drift knownActions=${known.length}');
      // Keep local migration diagnostics when both local readers are empty.
      if (known.isEmpty) {
        final diag = await _ref.read(securityBridgeProvider).v2Diag();
        if (diag != null) otaDiagLog('cmd.drift v2diag $diag');
        return; // mock mode or table empty — nothing to diff.
      }
      final unroutable = <String>[];
      for (final cmd in commandRegistry.values) {
        if (_kCommandDartOnly.contains(cmd.id)) continue;
        if (cmd.resolve != null) continue; // resolver maps at dispatch.
        if (!known.contains(cmd.id)) unroutable.add(cmd.id);
      }
      if (unroutable.isEmpty) {
        log.i('registry parity ok (${commandRegistry.length} commands)');
        return;
      }
      log.w(
        'command drift: ${unroutable.length} registered commands have '
        'no wire action — they will fail at runtime: $unroutable',
      );
    } catch (e) {
      log.w('command drift probe failed: $e');
    }
  }
}

/// Registry IDs that are intentionally Dart-only (in-app player,
/// status special-case in the router). Kept in sync with the parity
/// test at `test/features/_car_domain/command/registry_wire_parity_test.dart`.
const _kCommandDartOnly = <String>{
  'radio.next_fav',
  'radio.pause',
  'radio.play_by_name',
  'radio.play_station',
  'radio.resume',
  'radio.stop',
  'car.status',
};

/// Build a [BootSequence] from inside `_GateState.initState`. Not a
/// Riverpod provider because [WidgetRef] is gate-scoped and pinning
/// it inside a provider would prevent dispose. The lifecycle is
/// owned by `_GateState` (one `start()` per app session).
BootSequence buildBootSequence(WidgetRef ref) => BootSequence(ref);
