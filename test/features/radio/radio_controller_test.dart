import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/radio_favorites_store.dart';
import 'package:ilink/features/radio/data/radio_player.dart';
import 'package:ilink/features/radio/domain/radio_state.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio_player.dart';

/// Test station builder — same Station constructor the parser uses.
Station _st(String id, String name, {String? url}) => Station(
  id: id,
  sourceUuid: '',
  name: name,
  streamUrl: url ?? 'http://h/$id',
);

Future<ProviderContainer> _container({
  FakeRadioPlayer? player,
  Map<String, Object>? prefs,
}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      radioPlayerProvider.overrideWithValue(player ?? FakeRadioPlayer()),
      radioFavoritesStoreProvider.overrideWithValue(RadioFavoritesStore(sp)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle() => Future.delayed(Duration.zero);

void main() {
  // Asset bundle is needed because the controller eagerly indexes demo
  // playlists at build() time via rootBundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build() starts idle and transitions on player events', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player: player);
    final ctrl = c.read(radioControllerProvider.notifier);
    expect(c.read(radioControllerProvider), isA<RadioIdle>());

    final s = _st('a', 'Alpha');
    await ctrl.playStation(s);
    await _settle(); // let the broadcast stream deliver the playing state

    expect(c.read(radioControllerProvider), isA<RadioPlaying>());
    expect(player.played.single.id, 'a');
  });

  test('playByName resolves from the in-memory index', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player: player);
    final ctrl = c.read(radioControllerProvider.notifier);
    ctrl.indexStations([_st('jz', 'Frequence Jazz'), _st('rk', 'Rock 101')]);

    final out = await ctrl.playByName('jazz');
    expect(out.ok, isTrue);
    expect(player.played.single.id, 'jz');
  });

  test('playByName returns failure on empty query', () async {
    final c = await _container();
    final ctrl = c.read(radioControllerProvider.notifier);
    final out = await ctrl.playByName('   ');
    expect(out.ok, isFalse);
    expect(out.message, contains('empty'));
  });

  test('playByName returns failure when nothing matches', () async {
    final c = await _container();
    final ctrl = c.read(radioControllerProvider.notifier);
    ctrl.indexStations([_st('a', 'Alpha')]);
    final out = await ctrl.playByName('omega');
    expect(out.ok, isFalse);
    expect(out.message, contains('no station matches'));
  });

  test('playStationById prefers favourite snapshot over index', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player: player);
    final ctrl = c.read(radioControllerProvider.notifier);

    // Two stations with the same id but different names — favourite
    // wins so we can prove the snapshot path took precedence.
    final fav = _st('s1', 'From Favourite');
    final indexed = _st('s1', 'From Index');
    ctrl.indexStations([indexed]);
    await ctrl.toggleFavorite('s1', station: fav);
    player.played.clear();

    await ctrl.playStationById('s1');
    expect(player.played.single.name, 'From Favourite');
  });

  test('playStationById fails cleanly when id is unknown', () async {
    final c = await _container();
    final ctrl = c.read(radioControllerProvider.notifier);
    final out = await ctrl.playStationById('nope');
    expect(out.ok, isFalse);
    expect(out.message, contains('unknown station'));
  });

  test('pause/resume cycle updates state', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player: player);
    final ctrl = c.read(radioControllerProvider.notifier);

    await ctrl.playStation(_st('a', 'A'));
    await _settle();
    expect(c.read(radioControllerProvider), isA<RadioPlaying>());

    await ctrl.pause();
    await _settle();
    expect(c.read(radioControllerProvider), isA<RadioPaused>());

    await ctrl.resume();
    await _settle();
    expect(c.read(radioControllerProvider), isA<RadioPlaying>());
  });

  test('toggleFavorite persists snapshots and bumps version', () async {
    final c = await _container();
    final ctrl = c.read(radioControllerProvider.notifier);

    final v0 = c.read(favoritesVersionProvider);
    await ctrl.toggleFavorite('a', station: _st('a', 'Alpha'));
    expect(ctrl.isFavorite('a'), isTrue);
    expect(c.read(favoritesVersionProvider), greaterThan(v0));

    await ctrl.toggleFavorite('a');
    expect(ctrl.isFavorite('a'), isFalse);
  });

  test(
    'toggleFavorite without a snapshot fails when nothing is known',
    () async {
      final c = await _container();
      final ctrl = c.read(radioControllerProvider.notifier);
      final out = await ctrl.toggleFavorite('ghost');
      expect(out.ok, isFalse);
      expect(out.message, contains('unknown station'));
    },
  );

  test(
    'nextFavorite rotates through favourites in most-recent order',
    () async {
      final player = FakeRadioPlayer();
      final c = await _container(player: player);
      final ctrl = c.read(radioControllerProvider.notifier);

      await ctrl.toggleFavorite('s-1', station: _st('s-1', 'One'));
      await ctrl.toggleFavorite('s-2', station: _st('s-2', 'Two'));

      await ctrl.nextFavorite();
      expect(player.played.single.id, 's-2'); // most-recent first

      await ctrl.nextFavorite();
      expect(player.played.last.id, 's-1'); // wraps
    },
  );

  test('nextFavorite fails cleanly with no favourites', () async {
    final c = await _container();
    final ctrl = c.read(radioControllerProvider.notifier);
    final out = await ctrl.nextFavorite();
    expect(out.ok, isFalse);
    expect(out.message, 'no favorites');
  });

  test('player error propagates to RadioError', () async {
    final player = FakeRadioPlayer();
    final c = await _container(player: player);
    final ctrl = c.read(radioControllerProvider.notifier);

    await ctrl.playStation(_st('a', 'A'));
    player.emit(
      const RadioPlaybackState(
        status: RadioPlaybackStatus.error,
        errorMessage: 'stream 404',
      ),
    );
    await _settle();
    expect(c.read(radioControllerProvider), isA<RadioError>());
    expect(
      (c.read(radioControllerProvider) as RadioError).message,
      contains('stream 404'),
    );
  });
}
