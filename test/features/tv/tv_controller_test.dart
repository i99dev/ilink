import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tv/data/tv_favorites_store.dart';
import 'package:ilink/features/tv/domain/channel.dart';
import 'package:ilink/features/tv/domain/tv_quality.dart';
import 'package:ilink/features/tv/domain/tv_state.dart';
import 'package:ilink/features/tv/providers.dart';
import 'package:ilink/kernel/storage/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_tv_ivi_bridge.dart';

Channel _ch(String name, {String? url}) =>
    Channel.fromCatalogJson({'name': name, 'url': url ?? 'http://h/$name'});

Future<ProviderContainer> _container({
  FakeTvIviBridge? bridge,
  Map<String, Object>? prefs,
}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      tvFavoritesStoreProvider.overrideWithValue(TvFavoritesStore(sp)),
      tvIviBridgeProvider.overrideWithValue(bridge ?? FakeTvIviBridge()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build() starts idle', () async {
    final c = await _container();
    expect(c.read(tvControllerProvider), isA<TvIdle>());
  });

  test('playChannel launches the native player + tracks current', () async {
    final bridge = FakeTvIviBridge();
    final c = await _container(bridge: bridge);
    final ctrl = c.read(tvControllerProvider.notifier);

    final ch = _ch('Alpha');
    final out = await ctrl.playChannel(ch);

    expect(out.ok, isTrue);
    expect(bridge.launched.single.name, 'Alpha');
    expect(c.read(tvControllerProvider), isA<TvPlaying>());
    expect(c.read(tvLastChannelProvider), ch.id);
  });

  test('playChannel passes the saved quality cap', () async {
    final bridge = FakeTvIviBridge();
    final c = await _container(bridge: bridge, prefs: {'tv_quality': 'sd480'});
    await c.read(tvControllerProvider.notifier).playChannel(_ch('Alpha'));
    expect(c.read(tvQualityProvider), TvQuality.sd480);
    expect(bridge.lastMaxBitrate, TvQuality.sd480.maxBitrate);
  });

  test('playByName resolves from the in-memory index', () async {
    final bridge = FakeTvIviBridge();
    final c = await _container(bridge: bridge);
    final ctrl = c.read(tvControllerProvider.notifier);
    ctrl.indexChannels([_ch('BBC News'), _ch('Sky Sports')]);

    final out = await ctrl.playByName('sky');
    expect(out.ok, isTrue);
    expect(bridge.launched.single.name, 'Sky Sports');
  });

  test('playByName fails on empty query and on no match', () async {
    final c = await _container();
    final ctrl = c.read(tvControllerProvider.notifier);
    expect((await ctrl.playByName('  ')).ok, isFalse);
    ctrl.indexChannels([_ch('Alpha')]);
    final out = await ctrl.playByName('omega');
    expect(out.ok, isFalse);
    expect(out.message, contains('no channel matches'));
  });

  test('playChannelById prefers the favourite snapshot', () async {
    final bridge = FakeTvIviBridge();
    final c = await _container(bridge: bridge);
    final ctrl = c.read(tvControllerProvider.notifier);

    // Same URL (=> same id), different name; favourite must win.
    final fav = _ch('From Favourite', url: 'http://h/s1');
    final indexed = _ch('From Index', url: 'http://h/s1');
    ctrl.indexChannels([indexed]);
    await ctrl.toggleFavorite(fav.id, channel: fav);

    await ctrl.playChannelById(fav.id);
    expect(bridge.launched.single.name, 'From Favourite');
  });

  test('toggleFavorite persists snapshots and bumps version', () async {
    final c = await _container();
    final ctrl = c.read(tvControllerProvider.notifier);
    final ch = _ch('Fav');

    final v0 = c.read(tvFavoritesVersionProvider);
    await ctrl.toggleFavorite(ch.id, channel: ch);
    expect(ctrl.isFavorite(ch.id), isTrue);
    expect(c.read(tvFavoritesVersionProvider), greaterThan(v0));

    await ctrl.toggleFavorite(ch.id);
    expect(ctrl.isFavorite(ch.id), isFalse);
  });

  test(
    'toggleFavorite fails when nothing is known about the channel',
    () async {
      final c = await _container();
      final ctrl = c.read(tvControllerProvider.notifier);
      final out = await ctrl.toggleFavorite('ghost');
      expect(out.ok, isFalse);
      expect(out.message, contains('unknown channel'));
    },
  );
}
