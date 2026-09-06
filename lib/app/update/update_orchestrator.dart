import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/app/update/update_controller.dart';
import 'package:ilink/app/update/update_state.dart';
import 'package:ilink/kernel/observability/ota_diag_log.dart' show otaDiagLog;
import 'package:ilink/kernel/lifecycle/app_lifecycle_bus.dart';
import 'package:ilink/kernel/services/optional_services.dart';

import '../../../features/voice/state/voice_controller.dart';

// Keep diagnostics in kernel; callers may also use this composition-layer export.
export 'package:ilink/kernel/observability/ota_diag_log.dart' show otaDiagLog;

void _log(String message) => otaDiagLog(message);

// Tracks how many mini-app WebView sessions are currently open.
// MiniAppViewer increments on mount and decrements on dispose via
// `ref.read(activeMiniAppSessionCountProvider.notifier).increment()`.
final activeMiniAppSessionCountProvider = NotifierProvider<_IntNotifier, int>(
  _IntNotifier.new,
);

// Tracks whether any system dialog or bottom-sheet is currently visible.
// The OtaNavigatorObserver flips this on dialog route push/pop.
final dialogVisibleProvider = NotifierProvider<_BoolNotifier, bool>(
  _BoolNotifier.new,
);

// When a check fires but conditions are wrong for a prompt, the manifest
// is parked here. The orchestrator re-evaluates on every `resumed` event.
final pendingPromptManifestProvider =
    NotifierProvider<_PendingManifestNotifier, UpdateAvailable?>(
      _PendingManifestNotifier.new,
    );

// The manifest the update prompt UI should display. Set by the orchestrator
// when all idle conditions are met; cleared when the user acts on the prompt.
final promptUpdateProvider =
    NotifierProvider<_PendingManifestNotifier, UpdateAvailable?>(
      _PendingManifestNotifier.new,
    );

class _IntNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
  void decrement() => state = (state - 1).clamp(0, 9999);
}

class _BoolNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  // ignore: avoid_setters_without_getters
  set value(bool v) => state = v;
}

class _PendingManifestNotifier extends Notifier<UpdateAvailable?> {
  @override
  UpdateAvailable? build() => null;

  // ignore: avoid_setters_without_getters
  set value(UpdateAvailable? v) => state = v;
}

// Resume checks use a one-hour cooldown. Boot and explicit opt-in trigger an
// immediate check; there is no periodic/background polling timer.
const _kRecheckCooldown = Duration(hours: 1);
const _kPromptCooldown = Duration(hours: 24);

final updateClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

class UpdateOrchestrator {
  UpdateOrchestrator(this._ref) {
    _resumedSub = _ref.read(appLifecycleBusProvider).onResumed.listen((_) {
      _maybeRecheckAndPrompt();
    });
  }

  final Ref _ref;
  StreamSubscription<void>? _resumedSub;
  DateTime? _lastCheckAt;
  DateTime? _lastPromptAt;
  Object? _activeCheck;
  bool _disposed = false;
  DateTime get _now => _ref.read(updateClockProvider)();

  void consentRevoked() {
    // Allow a fresh check immediately after re-enable. An older canceled
    // response cannot clear a newer check's marker or publish its prompt.
    _activeCheck = null;
    _lastCheckAt = null;
  }

  void _maybeRecheckAndPrompt() {
    final now = _now;
    final lastCheck = _lastCheckAt;
    if (lastCheck == null || now.difference(lastCheck) > _kRecheckCooldown) {
      triggerCheck();
    } else {
      _tryShowPendingPrompt();
    }
  }

  /// Automatic discovery only. Download and installer handoff are owner actions.
  Future<void> triggerCheck() async {
    if (_disposed ||
        !_ref.read(serviceEnabledProvider(OptionalService.updates))) {
      return;
    }
    final current = _ref.read(updateControllerProvider).value;
    if (_activeCheck != null ||
        current is UpdateChecking ||
        current is UpdateDownloading ||
        current is UpdateReadyToInstall ||
        current is UpdateInstalling) {
      return;
    }
    final token = Object();
    _activeCheck = token;
    _lastCheckAt = _now;
    try {
      await _ref.read(updateControllerProvider.future);
      if (_disposed || !identical(_activeCheck, token)) return;
      await _ref.read(updateControllerProvider.notifier).check();
      if (_disposed || !identical(_activeCheck, token)) return;
      _tryShowPendingPrompt();
    } finally {
      if (identical(_activeCheck, token)) _activeCheck = null;
    }
  }

  void _tryShowPendingPrompt() {
    if (!_ref.read(serviceEnabledProvider(OptionalService.updates))) return;
    final updateState = _ref.read(updateControllerProvider).value;
    if (updateState is! UpdateAvailable) {
      _log('prompt skipped: state is not UpdateAvailable ($updateState)');
      return;
    }

    final manifest = updateState.manifest;
    final isForce = manifest.requiresForceUpdate(
      _ref.read(installedVersionCodeProvider).value ?? 0,
    );

    if (!isForce) {
      final last = _lastPromptAt;
      if (last != null && _now.difference(last) < _kPromptCooldown) {
        _log(
          'prompt parked: 24h cooldown active (last=${last.toIso8601String()})',
        );
        _ref.read(pendingPromptManifestProvider.notifier).value = updateState;
        return;
      }
    }

    if (!_idleConditionsMet()) {
      _log('prompt parked: idle gates not met');
      _ref.read(pendingPromptManifestProvider.notifier).value = updateState;
      return;
    }

    _log(
      'prompt firing for ${updateState.manifest.versionName} '
      '(vc ${updateState.manifest.versionCode}, force=$isForce)',
    );
    _lastPromptAt = _now;
    _ref.read(pendingPromptManifestProvider.notifier).value = null;
    _ref.read(promptUpdateProvider.notifier).value = updateState;
  }

  bool _idleConditionsMet() {
    // A request may take seconds. Test the current foreground state, not a
    // 250ms window after resume which expires before real network replies.
    if (!_ref.read(appLifecycleBusProvider).isResumed) return false;

    // Condition 2: no mini-app WebView session is active.
    final miniCount = _ref.read(activeMiniAppSessionCountProvider);
    if (miniCount > 0) {
      _log('idle gate 2 fail: $miniCount mini-app session(s) active');
      return false;
    }

    // Condition 3: no system dialog is visible.
    if (_ref.read(dialogVisibleProvider)) {
      _log('idle gate 3 fail: dialog visible');
      return false;
    }

    // Condition 4: no active voice interaction.
    // TODO(voice-idle): refine once a dedicated isVoiceActive selector lands.
    final voiceState = _ref.read(voiceControllerProvider);
    final isVoiceActive = voiceState is! VoiceIdle && voiceState is! VoiceError;
    if (isVoiceActive) {
      _log('idle gate 4 fail: voice active ($voiceState)');
      return false;
    }

    return true;
  }

  void dispose() {
    _disposed = true;
    _activeCheck = null;
    _resumedSub?.cancel();
    _resumedSub = null;
  }
}

final updateOrchestratorProvider = Provider<UpdateOrchestrator>((ref) {
  final orchestrator = UpdateOrchestrator(ref);
  ref.listen(serviceEnabledProvider(OptionalService.updates), (
    previous,
    enabled,
  ) {
    if (enabled) {
      // Runs after provider/widget construction, once persisted consent is known.
      unawaited(Future<void>.microtask(orchestrator.triggerCheck));
    } else if (previous == true) {
      orchestrator.consentRevoked();
      ref.read(pendingPromptManifestProvider.notifier).value = null;
      ref.read(promptUpdateProvider.notifier).value = null;
      ref.read(updateControllerProvider.notifier).defer();
    }
  }, fireImmediately: true);
  ref.onDispose(orchestrator.dispose);
  return orchestrator;
});
