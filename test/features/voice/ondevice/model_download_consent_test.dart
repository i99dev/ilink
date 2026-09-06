import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/ondevice/ondevice_voice_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/offline_model_consent');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'setModelDownloadsEnabled'
              ? true
              : <String, Object?>{'ok': true};
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('both model providers default to offline provisioning', () async {
    final recognizer = PlatformOnDeviceRecognizer(method: channel);
    await recognizer.provisionModel(
      url: 'https://example.test/model.zip',
      version: 'en-1',
    );
    await recognizer.provisionFallback(
      url: 'https://example.test/fallback.zip',
      version: 'ar-1',
    );
    expect(calls.map((call) => (call.arguments as Map)['allowNetwork']), [
      false,
      false,
    ]);
  });

  test('explicit consent and revocation reach native transport', () async {
    final recognizer = PlatformOnDeviceRecognizer(method: channel);
    await recognizer.setModelDownloadsEnabled(true);
    await recognizer.provisionModel(
      url: 'https://example.test/model.zip',
      version: 'en-1',
      allowNetwork: true,
    );
    await recognizer.setModelDownloadsEnabled(false);
    expect(calls[0].arguments, {'enabled': true});
    expect((calls[1].arguments as Map)['allowNetwork'], isTrue);
    expect(calls[2].arguments, {'enabled': false});
  });
}
