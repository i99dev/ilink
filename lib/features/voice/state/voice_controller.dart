import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'voice_access_gate.dart';
import '../data/voice_service_bridge.dart';
import '../ondevice/ondevice_voice_controller.dart';

sealed class VoiceSessionState {
  const VoiceSessionState();
}

class VoiceIdle extends VoiceSessionState {
  const VoiceIdle();
}

class VoiceConnecting extends VoiceSessionState {
  const VoiceConnecting();
}

class VoiceListening extends VoiceSessionState {
  const VoiceListening();
}

class VoiceThinking extends VoiceSessionState {
  const VoiceThinking();
}

class VoiceSpeaking extends VoiceSessionState {
  const VoiceSpeaking();
}

class VoiceReconnecting extends VoiceSessionState {
  const VoiceReconnecting(this.attempt);
  final int attempt;
}

enum VoiceErrorCode { micPermissionDenied, sttFailed, vadFailed, unknown }

class VoiceError extends VoiceSessionState {
  const VoiceError(this.message, {this.code = VoiceErrorCode.unknown});
  final String message;
  final VoiceErrorCode code;
}

/// Adapts local recognition to the assistant UI and hardware key.
class VoiceController extends Notifier<VoiceSessionState> {
  DateTime? lastHardwareKeyRejection;
  bool _starting = false;
  int _generation = 0;
  void clearHardwareKeyRejection() => lastHardwareKeyRejection = null;
  @override
  VoiceSessionState build() {
    final sub = ref.read(voiceServiceBridgeProvider).events.listen((event) {
      if (event == VoiceEventType.hardwareKey) {
        if (state is VoiceListening || state is VoiceConnecting) {
          unawaited(stop());
        } else if (canStartVoice(ref)) {
          unawaited(start());
        } else {
          lastHardwareKeyRejection = DateTime.now();
        }
      } else if (event == VoiceEventType.audioFocusLoss) {
        unawaited(stop());
      }
    });
    ref.listen(onDeviceVoiceControllerProvider, (_, next) {
      state = switch (next.status) {
        OnDeviceVoiceStatus.listening => const VoiceListening(),
        OnDeviceVoiceStatus.error => VoiceError(
          next.error ?? 'Local speech failed',
        ),
        _ => const VoiceIdle(),
      };
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
    });
    return const VoiceIdle();
  }

  Future<void> start() async {
    if (_starting || !canStartVoice(ref)) return;
    _starting = true;
    final generation = ++_generation;
    state = const VoiceConnecting();
    try {
      var permission = await Permission.microphone.status;
      if (!permission.isGranted) {
        permission = await Permission.microphone.request();
      }
      if (!ref.mounted || generation != _generation) return;
      if (!permission.isGranted) {
        state = const VoiceError(
          'Microphone permission is required for voice commands.',
          code: VoiceErrorCode.micPermissionDenied,
        );
        return;
      }
      final local = ref.read(onDeviceVoiceControllerProvider.notifier);
      // Native provisioning uses the bundled English archive before any
      // optional download, including on a fresh hardware-key invocation.
      final ready = await local.ensureModelReady();
      if (!ref.mounted || generation != _generation) return;
      if (!ready || !await local.startManualTurn(offlineOnly: true)) {
        if (ref.mounted && generation == _generation) {
          state = const VoiceError(
            'A local speech model is unavailable. Open Settings to set it up.',
          );
        }
      }
    } catch (_) {
      if (ref.mounted && generation == _generation) {
        state = const VoiceError(
          'Local voice could not start. Check microphone permission and the speech model.',
        );
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    _generation++;
    await ref.read(onDeviceVoiceControllerProvider.notifier).cancelManualTurn();
    if (ref.mounted) state = const VoiceIdle();
  }
}

final voiceControllerProvider =
    NotifierProvider<VoiceController, VoiceSessionState>(VoiceController.new);

class RecentToolDispatch {
  const RecentToolDispatch({
    required this.toolName,
    required this.arguments,
    required this.predictiveFired,
    required this.firedAt,
    this.label,
    this.onDeviceConfirmed = false,
    this.error,
  });
  final String toolName;
  final Map<String, dynamic> arguments;
  final bool predictiveFired;
  final DateTime firedAt;

  final String? label;

  final bool onDeviceConfirmed;

  /// Set when an on-device command was recognized but the dispatch FAILED
  /// (gate rejection / unsupported / daemon error). Carries a short driver-
  /// facing reason; the chip renders a warning instead of a success check so
  /// a "heard but didn't actuate" never looks like it worked.
  final String? error;
}

class RecentToolDispatchNotifier extends Notifier<RecentToolDispatch?> {
  static const Duration displayWindow = Duration(seconds: 3);

  Timer? _clearTimer;

  @override
  RecentToolDispatch? build() {
    ref.onDispose(() => _clearTimer?.cancel());
    return null;
  }

  void confirmLocalCommand({
    required String commandId,
    required Map<String, dynamic> arguments,
    String? label,
  }) {
    state = RecentToolDispatch(
      toolName: commandId,
      arguments: arguments,
      predictiveFired: true,
      firedAt: DateTime.now(),
      label: label,
      onDeviceConfirmed: true,
    );
    _arm();
  }

  /// An on-device command was recognized but the dispatch FAILED — surface
  /// the reason as a warning chip so "heard but the car didn't move" never
  /// masquerades as success. [reason] is already driver-friendly.
  void failLocalCommand({
    required String commandId,
    required String reason,
    String? label,
  }) {
    state = RecentToolDispatch(
      toolName: commandId,
      arguments: const {},
      predictiveFired: true,
      firedAt: DateTime.now(),
      label: label,
      error: reason,
    );
    _arm();
  }

  void _arm() {
    _clearTimer?.cancel();
    _clearTimer = Timer(displayWindow, () {
      // Re-check before clearing — a newer fire() may have come in
      // and queued its own timer; we only clear if WE'RE the latest.
      state = null;
    });
  }
}

final recentToolDispatchProvider =
    NotifierProvider<RecentToolDispatchNotifier, RecentToolDispatch?>(
      RecentToolDispatchNotifier.new,
    );
