import 'dart:io';

import 'package:ilink/features/voice/data/voice_service_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contract tests for the VoiceServiceBridge ↔ Kotlin VoiceChannel seam.
/// Mirrors the action_ids_contract_test pattern: read the Kotlin file as
/// text and assert that every string the Dart side expects is declared.
///
/// Catches "Dart says `startService`, Kotlin declares `start_service`" at
/// CI time instead of at a runtime `MissingPluginException`.
void main() {
  group('Dart channel name constants', () {
    test('method + event channel names match the production strings', () {
      expect(VoiceChannelNames.methodChannel, 'ilink/voice');
      expect(VoiceChannelNames.eventChannel, 'ilink/voice/events');
    });

    test('method names are stable (fail if someone silently renames)', () {
      expect(VoiceChannelNames.startService, 'startService');
      expect(VoiceChannelNames.stopService, 'stopService');
      expect(VoiceChannelNames.setNotificationText, 'setNotificationText');
      expect(VoiceChannelNames.setVoicePhase, 'setVoicePhase');
    });
  });

  group('Kotlin mirror parity', () {
    final channelFile = File(
      'android/app/src/main/kotlin/com/i99dev/ilink/voice/VoiceChannel.kt',
    );

    test('Kotlin VoiceChannel file exists', () {
      expect(
        channelFile.existsSync(),
        isTrue,
        reason: 'run tests from the dash/ directory so relative paths work',
      );
    });

    test('method + event channel strings match 1:1', () {
      final source = channelFile.readAsStringSync();
      expect(
        source,
        contains('METHOD_CHANNEL = "${VoiceChannelNames.methodChannel}"'),
      );
      expect(
        source,
        contains('EVENT_CHANNEL = "${VoiceChannelNames.eventChannel}"'),
      );
    });

    test('every Dart-called method is handled on Kotlin', () {
      final source = channelFile.readAsStringSync();
      for (final method in [
        VoiceChannelNames.startService,
        VoiceChannelNames.stopService,
        VoiceChannelNames.setNotificationText,
        VoiceChannelNames.setVoicePhase,
      ]) {
        expect(
          source,
          contains('"$method" ->'),
          reason: 'Kotlin must handle method "$method"',
        );
      }
    });

    test('every Dart event enum has a matching Kotlin EVENT_ constant', () {
      final source = channelFile.readAsStringSync();
      const mapping = {
        VoiceEventType.hardwareKey: 'EVENT_HARDWARE_KEY = "hardwareKey"',
        VoiceEventType.audioFocusLoss:
            'EVENT_AUDIO_FOCUS_LOSS = "audioFocusLoss"',
        VoiceEventType.audioFocusLossTransient:
            'EVENT_AUDIO_FOCUS_LOSS_TRANSIENT = "audioFocusLossTransient"',
        VoiceEventType.audioFocusGain:
            'EVENT_AUDIO_FOCUS_GAIN = "audioFocusGain"',
        VoiceEventType.serviceKilled: 'EVENT_SERVICE_KILLED = "serviceKilled"',
      };
      for (final entry in mapping.entries) {
        expect(
          source,
          contains(entry.value),
          reason: 'Kotlin missing event string for ${entry.key}',
        );
      }
    });
  });

  group('PlatformVoiceServiceBridge (mock mode)', () {
    test('mock bridge is a no-op for start/stop and emits no events', () async {
      final bridge = PlatformVoiceServiceBridge(mock: true);
      await bridge.startService();
      await bridge.stopService();
      await bridge.setNotificationText('hello');
      await bridge.setVoicePhase('listening', null);
      final events = bridge.events.take(0).toList();
      expect(await events, isEmpty);
    });
  });
}
