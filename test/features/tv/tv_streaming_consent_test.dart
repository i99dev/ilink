import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tv/data/tv_ivi_bridge.dart';
import 'package:ilink/features/tv/domain/channel.dart';
import 'package:ilink/kernel/services/optional_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ilink/tv_ivi');
  late List<String> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  Future<void> play(TvIviBridge bridge) => bridge.play(
    channels: [
      const Channel(
        id: 'one',
        name: 'One',
        streamUrl: 'https://example.com/live.m3u8',
      ),
    ],
    startIndex: 0,
  );
  test('default-off bridge does not contact native player', () async {
    await expectLater(play(TvIviBridge()), throwsA(isA<ServiceDisabled>()));
    expect(calls, isEmpty);
  });
  test('opt-in plays and revocation stops native playback', () async {
    var enabled = true;
    final bridge = TvIviBridge(streamingEnabled: () => enabled);
    await play(bridge);
    enabled = false;
    await bridge.stop();
    await expectLater(play(bridge), throwsA(isA<ServiceDisabled>()));
    expect(calls, ['play', 'stop']);
  });
  test(
    'direct local video remains available without streaming consent',
    () async {
      await TvIviBridge().play(
        channels: [
          const Channel(
            id: 'local',
            name: 'Local',
            streamUrl: 'file:///movies/local.mp4',
          ),
        ],
        startIndex: 0,
      );
      expect(calls, ['play']);
    },
  );
}
