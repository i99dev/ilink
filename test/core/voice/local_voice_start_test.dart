import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/voice/data/voice_service_bridge.dart';
import 'package:ilink/features/voice/ondevice/ondevice_voice_controller.dart';
import 'package:ilink/features/voice/state/voice_controller.dart';
import '../../support/fake_voice_service_bridge.dart';

class _Settings extends SettingsController {
  @override
  Future<AppSettings> build() async =>
      AppSettings.empty.copyWith(voiceAssistantEnabled: true);
}

class _Local extends OnDeviceVoiceController {
  _Local(this.calls, {this.readyFuture});
  final List<String> calls;
  final Future<bool>? readyFuture;
  @override
  OnDeviceVoiceState build() =>
      const OnDeviceVoiceState(OnDeviceVoiceStatus.idle);
  @override
  Future<bool> ensureModelReady() async {
    calls.add('provision-bundled');
    return await (readyFuture ?? Future.value(true));
  }

  @override
  Future<bool> startManualTurn({bool offlineOnly = true}) async {
    calls.add('capture');
    expect(offlineOnly, true);
    state = const OnDeviceVoiceState(OnDeviceVoiceStatus.listening);
    return true;
  }

  @override
  Future<void> cancelManualTurn() async {
    calls.add('stop');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  for (final granted in [true, false]) {
    test(
      'fresh voice start requests permission before bundled setup (granted=$granted)',
      () async {
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissions, (call) async {
              if (call.method == 'checkPermissionStatus') return 0;
              if (call.method == 'requestPermissions') {
                calls.add('permission');
                return {7: granted ? 1 : 0};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(permissions, null),
        );
        final bridge = FakeVoiceServiceBridge();
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            voiceServiceBridgeProvider.overrideWithValue(bridge),
            onDeviceVoiceControllerProvider.overrideWith(() => _Local(calls)),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(bridge.dispose);
        await container.read(settingsProvider.future);
        await container.read(voiceControllerProvider.notifier).start();
        expect(
          calls,
          granted
              ? ['permission', 'provision-bundled', 'capture']
              : ['permission'],
        );
        expect(
          container.read(voiceControllerProvider),
          granted ? isA<VoiceListening>() : isA<VoiceError>(),
        );
      },
    );
  }
  test(
    'stop during bundled setup does not open microphone afterwards',
    () async {
      final calls = <String>[];
      final ready = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissions, (call) async => 1);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissions, null),
      );
      final bridge = FakeVoiceServiceBridge();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          voiceServiceBridgeProvider.overrideWithValue(bridge),
          onDeviceVoiceControllerProvider.overrideWith(
            () => _Local(calls, readyFuture: ready.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(bridge.dispose);
      await container.read(settingsProvider.future);
      final controller = container.read(voiceControllerProvider.notifier);
      final started = controller.start();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['provision-bundled']);
      await controller.stop();
      ready.complete(true);
      await started;
      expect(calls, ['provision-bundled', 'stop']);
      expect(container.read(voiceControllerProvider), isA<VoiceIdle>());
    },
  );
}
