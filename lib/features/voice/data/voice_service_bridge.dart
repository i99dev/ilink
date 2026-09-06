import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Events pushed from Kotlin's [VoiceChannel] / [VoiceSessionService] into
/// Dart. String values mirror the `EVENT_*` constants declared on the
/// Kotlin side — keep them in sync (see voice_service_bridge_contract_test).
enum VoiceEventType {
  hardwareKey,
  audioFocusLoss,
  audioFocusLossTransient,
  audioFocusGain,
  serviceKilled,
}

VoiceEventType? _parseEvent(String? raw) => switch (raw) {
  'hardwareKey' => VoiceEventType.hardwareKey,
  'audioFocusLoss' => VoiceEventType.audioFocusLoss,
  'audioFocusLossTransient' => VoiceEventType.audioFocusLossTransient,
  'audioFocusGain' => VoiceEventType.audioFocusGain,
  'serviceKilled' => VoiceEventType.serviceKilled,
  _ => null,
};

/// Seam over the voice-session platform surface:
///
///   - [startService] / [stopService] control the foreground service that
///     keeps the Flutter engine alive across app backgrounding.
///   - [events] surfaces hardware-key presses + audio-focus changes so
///     [VoiceController] can start/pause/stop without polling.
///
/// Mirrors the [CarBridge] pattern — abstract class + concrete impl +
/// provider + test fake — so tests of [VoiceController] can run without
/// a platform channel.
abstract class VoiceServiceBridge {
  Future<void> startService();
  Future<void> stopService();
  Future<void> setNotificationText(String text);

  /// Push the current voice phase (+ active tool, if any) to the native
  /// side so the backgrounded floating bubble can render the matching glyph
  /// + earcon. No-op visually when the app is foregrounded (no bubble), so
  /// it's cheap to call on every phase change. [phase] is a
  /// `VoicePhaseWire` constant.
  Future<void> setVoicePhase(String phase, String? tool);

  Stream<VoiceEventType> get events;
}

class PlatformVoiceServiceBridge implements VoiceServiceBridge {
  PlatformVoiceServiceBridge({this.mock = false});

  final bool mock;

  static const _method = MethodChannel('ilink/voice');
  static const _event = EventChannel('ilink/voice/events');

  Stream<VoiceEventType>? _cachedStream;

  @override
  Stream<VoiceEventType> get events {
    if (mock) return const Stream<VoiceEventType>.empty();
    return _cachedStream ??= _event
        .receiveBroadcastStream()
        .map((raw) {
          if (raw is! Map) return null;
          return _parseEvent(raw['type'] as String?);
        })
        .where((e) => e != null)
        .cast<VoiceEventType>();
  }

  @override
  Future<void> startService() async {
    if (mock) return;
    await _method.invokeMethod<void>('startService');
  }

  @override
  Future<void> stopService() async {
    if (mock) return;
    await _method.invokeMethod<void>('stopService');
  }

  @override
  Future<void> setNotificationText(String text) async {
    if (mock) return;
    await _method.invokeMethod<void>('setNotificationText', {'text': text});
  }

  @override
  Future<void> setVoicePhase(String phase, String? tool) async {
    if (mock) return;
    try {
      await _method.invokeMethod<void>('setVoicePhase', {
        'phase': phase,
        'tool': tool,
      });
    } on PlatformException {
      // Best-effort UI hint — never let it bubble into the session.
    } on MissingPluginException {
      // Non-Android / test harness without the channel registered.
    }
  }
}

/// Voice native channel only exists on Android (Kotlin
/// `VoiceSessionService`). Anywhere else — web, iOS, desktop — fall back
/// to the no-op bridge so the rest of the voice stack works without
/// throwing `MissingPluginException`. Independent of [AppConfig.mockCar];
/// mocking car data does not silence voice on a real device.
bool get _voiceNativeAvailable {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android;
}

final voiceServiceBridgeProvider = Provider<VoiceServiceBridge>((ref) {
  return PlatformVoiceServiceBridge(mock: !_voiceNativeAvailable);
});

/// Names used on the method channel. Referenced by the contract test to
/// prove the Kotlin `VoiceChannel` declares the same strings.
class VoiceChannelNames {
  VoiceChannelNames._();
  static const String methodChannel = 'ilink/voice';
  static const String eventChannel = 'ilink/voice/events';
  static const String startService = 'startService';
  static const String stopService = 'stopService';
  static const String setNotificationText = 'setNotificationText';
  static const String setVoicePhase = 'setVoicePhase';
}
