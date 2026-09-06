import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/ondevice/moonshine_engine_manager.dart';
import 'package:ilink/kernel/services/optional_services.dart';

/// No optional service consented — the shipped default.
class _NoServices implements ServicePreferences {
  @override
  Future<Set<OptionalService>> load() async => const <OptionalService>{};

  @override
  Future<void> save(Set<OptionalService> enabled) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ilink/ondevice_voice');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'fallbackModelPresent' => false,
            'setModelDownloadsEnabled' => true,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [servicePreferencesProvider.overrideWithValue(_NoServices())],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Regression: `build()` called `refresh()` directly. `refresh` is async but
  // runs synchronously up to its first `await`, and its guard reads `state` —
  // which Riverpod has not initialised until `build` returns. That threw
  // "Tried to read the state of an uninitialized provider" as an uncaught
  // async error every time the Settings tile was first built. An uncaught
  // error in the guarded test zone fails this test.
  test(
    'building the provider never reads state before it is initialised',
    () async {
      final container = makeContainer();

      expect(
        container.read(moonshineEngineManagerProvider).status,
        MoonshineEngineStatus.absent,
        reason: 'build() must return an optimistic absent state',
      );

      // Let the deferred refresh run to completion.
      await pumpEventQueue();

      expect(
        container.read(moonshineEngineManagerProvider).status,
        MoonshineEngineStatus.absent,
        reason: 'native reports the bundle missing, so it stays absent',
      );
    },
  );

  test('deferred refresh still reaches the native presence check', () async {
    final container = makeContainer();
    container.read(moonshineEngineManagerProvider);

    await pumpEventQueue();

    expect(
      calls,
      contains('fallbackModelPresent'),
      reason: 'deferring must not skip the on-disk resolve',
    );
  });
}
