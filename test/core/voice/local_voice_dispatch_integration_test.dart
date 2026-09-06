import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/features/_car_domain/router/command_router.dart';
import 'package:ilink/features/voice/state/voice_controller.dart';
import 'package:ilink/features/workflow/engine/workflow_engine.dart';
import 'package:ilink/features/workflow/engine/workflow_engine_provider.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/sdk/brands/byd/byd_client.dart';
import 'package:ilink/sdk/car/client.dart';
import 'package:ilink/sdk/car/gated_dispatcher.dart';

/// Real settings, local voice controllers, bridge, grammar/matcher, tool router,
/// BYD SDK, safety router and audit. Native channels/storage are simulated.
/// Does NOT decode PCM, extract Android model assets or actuate a vehicle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final scenario in [
    'parked',
    'moving',
    'integrity-denied',
    'unrecognized',
    'capture-error',
    'stopped-late-result',
  ]) {
    test('fresh offline voice reaches real safe dispatch: $scenario', () async {
      SharedPreferences.setMockInitialValues({});
      final calls = <String>[];
      final actions = <Map<dynamic, dynamic>>[];
      final audits = <Map<dynamic, dynamic>>[];
      var modelPresent = false;
      final channels = <String>[];
      void mock(String name, Future<Object?> Function(MethodCall) handler) {
        channels.add(name);
        messenger.setMockMethodCallHandler(MethodChannel(name), handler);
      }

      for (final channel in [
        'ilink/ondevice_voice/events',
        'ilink/ondevice_voice/provision',
        'ilink/ondevice_voice/utterance',
        'ilink/voice/events',
        'ilink/car/registry',
      ]) {
        mock(channel, (_) async => null);
      }
      mock('flutter.baseflow.com/permissions/methods', (call) async {
        if (call.method == 'checkPermissionStatus') return 0;
        if (call.method == 'requestPermissions') {
          calls.add('permission');
          return {7: 1};
        }
        throw StateError('Unexpected permission method: ${call.method}');
      });
      mock('ilink/ondevice_voice', (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'setModelDownloadsEnabled':
            expect(args['enabled'], false);
            return true;
          case 'modelPresent':
            expect(args['version'], 'en-0.15');
            return modelPresent;
          case 'provisionModel':
            calls.add('bundled-model-request');
            expect(args['version'], 'en-0.15');
            expect(args['allowNetwork'], false);
            modelPresent = true;
            return {'ok': true};
          case 'applyGrammar':
            calls.add('grammar');
            final phrases = jsonDecode(args['grammar'] as String) as List;
            expect(phrases, contains('open the driver window'));
            return {'ok': true};
          case 'start':
            calls.add('microphone-start');
            return null;
          case 'stop':
            calls.add('microphone-stop');
            return null;
          case 'dispose':
            return null;
          default:
            throw StateError('Unexpected recognizer method: ${call.method}');
        }
      });
      mock('ilink/car', (call) async {
        switch (call.method) {
          case 'runAction':
            actions.add(call.arguments as Map);
            return {'ok': true};
          case 'getValuesByName':
            return {
              'Statistic.STATISTIC_SPEED_SIG_VDIS': scenario == 'moving'
                  ? 40
                  : 0,
            };
          case 'daemonStatus':
            return {'daemon': true};
          case 'allCatalogNames':
            return <String, int>{};
          default:
            return null;
        }
      });
      mock('ilink/security', (call) async {
        if (call.method == 'integrityHealthy') {
          return scenario != 'integrity-denied';
        }
        if (call.method == 'logDispatch') audits.add(call.arguments as Map);
        return true;
      });
      final container = ProviderContainer(
        overrides: [
          appConfigBaseProvider.overrideWithValue(AppConfig.fromEnvironment()),
          // Same gate binding as main.dart. No fake safety/router/client.
          gatedDispatcherProvider.overrideWith((ref) {
            final router = ref.read(carCommandRouterProvider);
            return (action, args, {caller}) =>
                router.dispatch(action, args, caller: caller);
          }),
          // Pin the real adapter to avoid async brand changes during this test.
          carClientProvider.overrideWith((ref) => BydClient(ref)),
          // Fresh install has no automations: real empty engine, without the
          // unrelated location/notification subscriptions from app boot.
          workflowEngineProvider.overrideWith((ref) {
            final engine = WorkflowEngine();
            ref.onDispose(engine.dispose);
            return engine;
          }),
        ],
      );
      addTearDown(() async {
        final client = container.read(carClientProvider) as BydClient;
        await container.read(voiceControllerProvider.notifier).stop();
        container.dispose();
        await client.dispose();
        await Future<void>.delayed(Duration.zero);
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
      });
      final settings = await container.read(settingsProvider.future);
      expect(settings.deviceId, isEmpty);
      expect(settings.userId, 'local-device');
      expect(settings.voiceAssistantEnabled, true);
      expect(settings.devCarControlsEnabled, false);
      expect(settings.voiceModelLang, 'en-us');
      expect(await container.read(optionalServicesProvider.future), isEmpty);
      await container.read(voiceControllerProvider.notifier).start();
      expect(container.read(voiceControllerProvider), isA<VoiceListening>());
      expect(calls.take(4), [
        'permission',
        'bundled-model-request',
        'grammar',
        'microphone-start',
      ]);
      if (scenario == 'capture-error' || scenario == 'stopped-late-result') {
        if (scenario == 'capture-error') {
          await messenger.handlePlatformMessage(
            'ilink/ondevice_voice/events',
            codec.encodeErrorEnvelope(
              code: 'ondevice_voice',
              message: 'audiorecord_uninitialized',
            ),
            (_) {},
          );
        } else {
          await container.read(voiceControllerProvider.notifier).stop();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // A queued final must be discarded even if it contains a wake phrase.
        await messenger.handlePlatformMessage(
          'ilink/ondevice_voice/events',
          codec.encodeSuccessEnvelope({
            'text': 'hey byd open the driver window',
            'isFinal': true,
          }),
          (_) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls, contains('microphone-stop'));
        expect(actions, isEmpty);
        expect(audits, isEmpty);
        expect(container.read(recentToolDispatchProvider), isNull);
        expect(
          container.read(voiceControllerProvider),
          scenario == 'capture-error' ? isA<VoiceError>() : isA<VoiceIdle>(),
        );
        return;
      }
      await messenger.handlePlatformMessage(
        'ilink/ondevice_voice/events',
        codec.encodeSuccessEnvelope({
          'text': scenario == 'unrecognized'
              ? 'tell me a joke'
              : 'open the driver window',
          'isFinal': true,
        }),
        (_) {},
      );
      for (var i = 0; i < 50; i++) {
        if (container.read(recentToolDispatchProvider) != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final feedback = container.read(recentToolDispatchProvider);
      expect(calls, contains('microphone-stop'));
      expect(container.read(voiceControllerProvider), isA<VoiceIdle>());
      if (scenario == 'parked') {
        expect(actions, hasLength(1));
        expect(actions.single['id'], 'window.fl');
        expect(actions.single['args'], {'value': 1});
        expect(feedback?.toolName, 'window.fl.open');
        expect(feedback?.error, isNull);
        expect(audits.single['outcome'], 'ok');
      } else {
        expect(actions, isEmpty);
        if (scenario != 'unrecognized') {
          expect(feedback?.error, isNotNull);
          expect(
            audits.single['outcome'],
            scenario == 'moving'
                ? 'UNSAFE_WHILE_MOVING'
                : 'INTEGRITY_UNHEALTHY',
          );
        } else {
          expect(audits, isEmpty);
        }
      }
      if (audits.isNotEmpty) expect(audits.single['caller'], 'voice');
    });
  }
}
