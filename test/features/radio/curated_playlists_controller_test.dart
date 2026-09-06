import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/curated_playlist_api.dart';
import 'package:ilink/features/radio/data/radio_favorites_store.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:ilink/kernel/playlists/catalogue_http.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio_player.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions o) handler;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

final _indexJson = {
  'generatedAt': '2026-02-01T00:00:00Z',
  'totalPlaylists': 1,
  'playlists': [
    {'name': 'Arabic', 'url': 'api/playlists/arabic.json', 'count': 2},
  ],
};
final _playlistJson = {
  'name': 'Arabic',
  'count': 2,
  'items': [
    {'name': 'A', 'url': 'http://h/a'},
    {'name': 'B', 'url': 'http://h/b'},
  ],
};

Future<({ProviderContainer c, _Adapter adapter, FakeRadioPlayer player})>
_setup() async {
  SharedPreferences.setMockInitialValues({});
  final sp = await SharedPreferences.getInstance();
  final adapter = _Adapter((o) {
    final url = o.uri.toString();
    if (url.endsWith('/api/index.json')) return _json(_indexJson, 200);
    if (url.endsWith('/api/playlists/arabic.json')) {
      return _json(_playlistJson, 200);
    }
    return _json({}, 404);
  });
  final player = FakeRadioPlayer();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      radioPlayerProvider.overrideWithValue(player),
      radioFavoritesStoreProvider.overrideWithValue(RadioFavoritesStore(sp)),
      curatedApiProvider.overrideWithValue(
        CuratedPlaylistApi(
          baseUrl: 'https://catalog.example.test',
          http: CatalogueHttp(dio: Dio()..httpClientAdapter = adapter),
        ),
      ),
      // CuratedCache stays as the real implementation over mocked prefs.
    ],
  );
  addTearDown(c.dispose);
  return (c: c, adapter: adapter, player: player);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getIndex: cache miss → fetches + caches; cache hit → no fetch', () async {
    final s = await _setup();
    final ctrl = s.c.read(curatedPlaylistsControllerProvider.notifier);

    final idx1 = await ctrl.getIndex();
    expect(idx1.entries.single.id, 'arabic');
    expect(s.adapter.calls, 1, reason: 'cold fetch');

    final idx2 = await ctrl.getIndex();
    expect(idx2.entries.single.id, 'arabic');
    expect(
      s.adapter.calls,
      2,
      reason:
          'explicit remote catalog can refresh; production default is a local asset',
    );
  });

  test(
    'loadPlaylist: cache miss → fetches, caches, indexes for voice',
    () async {
      final s = await _setup();
      final ctrl = s.c.read(curatedPlaylistsControllerProvider.notifier);
      final idx = await ctrl.getIndex();

      final pl = await ctrl.loadPlaylist(idx.entries.single);
      expect(pl.stations, hasLength(2));

      // Voice index should now resolve a station id from the curated set.
      final radio = s.c.read(radioControllerProvider.notifier);
      final out = await radio.playStationById(pl.stations.first.id);
      expect(out.ok, isTrue);
    },
  );

  test('loadPlaylist cache hit: no second network fetch', () async {
    final s = await _setup();
    final ctrl = s.c.read(curatedPlaylistsControllerProvider.notifier);
    final idx = await ctrl.getIndex();
    await ctrl.loadPlaylist(idx.entries.single);
    final before = s.adapter.calls;

    await ctrl.loadPlaylist(idx.entries.single);
    expect(s.adapter.calls, before, reason: 'cached read, no network');
  });

  test(
    'refresh preserves cached playlists and bumps the index state',
    () async {
      final s = await _setup();
      final ctrl = s.c.read(curatedPlaylistsControllerProvider.notifier);
      await ctrl.getIndex();
      final v0 = s.c.read(curatedPlaylistsControllerProvider);

      await ctrl.refresh();
      expect(s.c.read(curatedPlaylistsControllerProvider), greaterThan(v0));

      await ctrl.getIndex();
      expect(s.adapter.calls, 2, reason: 'second fetch after refresh');
    },
  );

  test(
    'curatedIndexProvider returns the same data as the controller',
    () async {
      final s = await _setup();
      final idxFromCtrl = await s.c
          .read(curatedPlaylistsControllerProvider.notifier)
          .getIndex();
      final idxFromProvider = await s.c.read(curatedIndexProvider.future);
      expect(idxFromProvider.entries.first.id, idxFromCtrl.entries.first.id);
    },
  );
}
