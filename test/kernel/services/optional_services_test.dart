import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/kernel/api/dio_factory.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:ilink/kernel/services/service_network_policy.dart';

class _Adapter implements HttpClientAdapter {
  int calls = 0;
  Completer<ResponseBody>? response;
  Completer<void>? started;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    started?.complete();
    return response?.future ??
        ResponseBody.fromString(
          '{}',
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
  }

  @override
  void close({bool force = false}) {}
}

class _SlowPreferences implements ServicePreferences {
  final started = Completer<void>();
  final release = Completer<void>();
  Set<OptionalService> saved = {OptionalService.streaming};
  @override
  Future<Set<OptionalService>> load() async => saved;
  @override
  Future<void> save(Set<OptionalService> enabled) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    saved = {...enabled};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'revocation is immediate while an unrelated durable grant waits',
    () async {
      final prefs = _SlowPreferences();
      final container = ProviderContainer(
        overrides: [servicePreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await container.read(optionalServicesProvider.future);
      final controller = container.read(optionalServicesProvider.notifier);
      final grant = controller.setEnabled(OptionalService.updates, true);
      await prefs.started.future;
      final revoke = controller.setEnabled(OptionalService.streaming, false);
      expect(
        container
            .read(optionalServicesProvider)
            .value!
            .contains(OptionalService.streaming),
        isFalse,
      );
      prefs.release.complete();
      await Future.wait([grant, revoke]);
      expect(prefs.saved, {OptionalService.updates});
      expect(container.read(optionalServicesProvider).value, {
        OptionalService.updates,
      });
    },
  );

  test(
    'production transport factory makes zero external calls by default',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(optionalServicesProvider.future);
      for (final purpose in DioPurpose.values) {
        final adapter = _Adapter();
        final dio = container.read(dioProvider(purpose));
        dio.httpClientAdapter = adapter;
        await expectLater(
          dio.get<dynamic>('https://example.invalid/api/v1/account'),
          throwsA(isA<DioException>()),
        );
        expect(adapter.calls, 0, reason: purpose.name);
      }
    },
  );

  test(
    'fresh and legacy installations require explicit persisted consent',
    () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'legacy-fixture',
        'user_id': 'legacy-user',
        'audio_telemetry_consent': true,
      });
      final container = ProviderContainer();
      expect(
        container.read(serviceEnabledProvider(OptionalService.downloads)),
        isFalse,
      );
      expect(await container.read(optionalServicesProvider.future), isEmpty);
      await container
          .read(optionalServicesProvider.notifier)
          .setEnabled(OptionalService.downloads, true);
      expect(
        container.read(serviceEnabledProvider(OptionalService.streaming)),
        isFalse,
      );
      container.dispose();
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(await restarted.read(optionalServicesProvider.future), {
        OptionalService.downloads,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), 'legacy-fixture');
    },
  );

  test(
    'serialized simultaneous settings changes preserve both choices',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(optionalServicesProvider.future);
      final controller = container.read(optionalServicesProvider.notifier);
      await Future.wait([
        controller.setEnabled(OptionalService.updates, true),
        controller.setEnabled(OptionalService.streaming, true),
      ]);
      expect(container.read(optionalServicesProvider).value, {
        OptionalService.updates,
        OptionalService.streaming,
      });
    },
  );

  test('invalid stored preferences fail closed', () async {
    SharedPreferences.setMockInitialValues({DeviceServicePreferences.key: 42});
    expect(await DeviceServicePreferences().load(), isEmpty);
  });

  test('removed tracking and unknown API routes have no enabling flag', () {
    for (final path in [
      '/api/v1/voice/telemetry',
      '/api/v1/voice/timings',
      '/api/v1/security/integrity',
      '/api/v1/cars/id/mqtt/regenerate-credentials',
      '/api/v1/oauth/google-link/status',
      '/api/v1/new-unreviewed-route',
    ]) {
      expect(backendServiceFor(path), isNull, reason: path);
    }
    expect(backendServiceFor('/api/v1/billing/checkout'), isNull);
    expect(backendServiceFor('/api/v1/voice/credits/balance'), isNull);
    expect(backendServiceFor('/api/v1/automation/workflows'), isNull);
  });

  test(
    'disabled provider never reaches a functioning network adapter',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        ServiceNetworkInterceptor(
          classify: (_) => OptionalService.downloads,
          isEnabled: (_) => false,
        ),
      );
      await expectLater(
        dio.get<void>('https://example.invalid/model'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 0);
      dio.close();
    },
  );

  test(
    'opt-in retains real request/response behavior; revocation cancels work',
    () async {
      var enabled = true;
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final guard = ServiceNetworkInterceptor(
        classify: (_) => OptionalService.downloads,
        isEnabled: (_) => enabled,
      );
      dio.interceptors.add(guard);
      expect(
        (await dio.get<Object?>('https://example.invalid/model')).statusCode,
        200,
      );
      adapter.response = Completer<ResponseBody>();
      adapter.started = Completer<void>();
      final cancel = CancelToken();
      final pending = dio.get<Object?>(
        'https://example.invalid/model',
        cancelToken: cancel,
      );
      final assertion = expectLater(pending, throwsA(isA<DioException>()));
      await adapter.started!.future;
      enabled = false;
      guard.revokeDisabled();
      expect(cancel.isCancelled, isTrue);
      adapter.response!.complete(ResponseBody.fromString('{}', 200));
      await assertion;
      expect(adapter.calls, 2);
      dio.close();
    },
  );
}
