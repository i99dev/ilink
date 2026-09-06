import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/radio_favorites_store.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:ilink/features/radio/radio_voice_dispatch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio_player.dart';

/// Regression: voice radio control. The `radio_assistant` subagent
/// dispatches `radio.*` through this handler, which must drive the in-app
/// [RadioController] — NOT the daemon (radio has no wire action, so the
/// old generic path 500'd into "I don't have access to the radio
/// control").

Station _st(String id, String name) =>
    Station(id: id, sourceUuid: '', name: name, streamUrl: 'http://h/$id');

Future<ProviderContainer> _container(FakeRadioPlayer player) async {
  SharedPreferences.setMockInitialValues({});
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      radioPlayerProvider.overrideWithValue(player),
      radioFavoritesStoreProvider.overrideWithValue(RadioFavoritesStore(sp)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  // Controller indexes demo playlists from the asset bundle at build().
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'radio.play_by_name plays the matching station via the controller',
    () async {
      final player = FakeRadioPlayer();
      final c = await _container(player);
      final ctrl = c.read(radioControllerProvider.notifier);
      ctrl.indexStations([_st('jz', 'Frequence Jazz'), _st('rk', 'Rock 101')]);

      final res = await dispatchRadioCommand(ctrl, 'radio.play_by_name', {
        'name': 'jazz',
      });

      expect(res['ok'], isTrue);
      expect(player.played.single.id, 'jz');
    },
  );

  test('radio.play_by_name with no match returns an error result', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player);
    final ctrl = c.read(radioControllerProvider.notifier);
    ctrl.indexStations([_st('rk', 'Rock 101')]);

    final res = await dispatchRadioCommand(ctrl, 'radio.play_by_name', {
      'name': 'jazz',
    });

    expect(res.containsKey('error'), isTrue);
    expect(player.played, isEmpty);
  });

  test('pause / resume / stop route to the player', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player);
    final ctrl = c.read(radioControllerProvider.notifier);
    ctrl.indexStations([_st('a', 'Alpha')]);
    await dispatchRadioCommand(ctrl, 'radio.play_by_name', {'name': 'alpha'});

    expect((await dispatchRadioCommand(ctrl, 'radio.pause', {}))['ok'], isTrue);
    expect(
      (await dispatchRadioCommand(ctrl, 'radio.resume', {}))['ok'],
      isTrue,
    );
    expect((await dispatchRadioCommand(ctrl, 'radio.stop', {}))['ok'], isTrue);
    expect(player.pauseCalls, 1);
    expect(player.resumeCalls, 1);
    expect(player.stopCalls, 1);
  });

  test('unknown radio command returns an error', () async {
    final c = await _container(FakeRadioPlayer());
    final ctrl = c.read(radioControllerProvider.notifier);

    final res = await dispatchRadioCommand(ctrl, 'radio.bogus', {});

    expect(res['error'], contains('unknown radio command'));
  });
}
