import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/m3u_parser.dart';
import 'package:ilink/features/radio/data/radio_favorites_store.dart';
import 'package:ilink/features/radio/data/user_playlist_importer.dart';
import 'package:ilink/features/radio/domain/user_playlist.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio_player.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions o) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _text(String body, int status) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/plain'],
  },
);

const _m3u = '''
#EXTM3U
#EXTINF:-1, Alpha
http://h/a
#EXTINF:-1, Bravo
http://h/b
''';

Future<({ProviderContainer c, FakeRadioPlayer player, Directory storeDir})>
_setup({
  FutureOr<ResponseBody> Function(RequestOptions)? handler,
  Directory? storeDir,
}) async {
  SharedPreferences.setMockInitialValues({});
  final sp = await SharedPreferences.getInstance();
  // When [storeDir] is supplied the caller is simulating a cold reopen
  // over an existing on-disk store, so this container does NOT own the
  // dir and must not delete it on teardown.
  final ownsDir = storeDir == null;
  final dir = storeDir ?? await Directory.systemTemp.createTemp('upc_test_');
  final adapter = _Adapter(handler ?? (_) => _text('', 404));
  final dio = Dio()..httpClientAdapter = adapter;
  final player = FakeRadioPlayer();
  final c = ProviderContainer(
    overrides: [
      radioPlayerProvider.overrideWithValue(player),
      radioFavoritesStoreProvider.overrideWithValue(RadioFavoritesStore(sp)),
      userPlaylistDirProvider.overrideWithValue(dir),
      userPlaylistImporterProvider.overrideWithValue(
        UserPlaylistImporter(dio: dio, parser: (b) async => parseM3u(b)),
      ),
    ],
  );
  addTearDown(() async {
    c.dispose();
    if (ownsDir && await dir.exists()) await dir.delete(recursive: true);
  });
  return (c: c, player: player, storeDir: dir);
}

Future<void> _settle() => Future.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'addFromUrl: stores, bumps version, indexes into voice search',
    () async {
      final s = await _setup(handler: (_) => _text(_m3u, 200));
      final ctrl = s.c.read(userPlaylistControllerProvider.notifier);
      final v0 = s.c.read(userPlaylistsVersionProvider);

      final out = await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
      expect(out.ok, isTrue);

      final list = s.c.read(userPlaylistsProvider);
      expect(list.single.name, 'List');
      expect(list.single.entryCount, 2);
      expect(s.c.read(userPlaylistsVersionProvider), greaterThan(v0));

      // Voice search now resolves a station from the new playlist.
      final id = list.single.stations.first.id;
      final radio = s.c.read(radioControllerProvider.notifier);
      final play = await radio.playStationById(id);
      await _settle();
      expect(play.ok, isTrue);
      expect(s.player.played.single.id, id);
    },
  );

  test('addFromUrl failure surfaces importer message', () async {
    final s = await _setup(handler: (_) => _text('', 404));
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);
    final out = await ctrl.addFromUrl('https://h/x.m3u', name: 'X');
    expect(out.ok, isFalse);
    expect(out.message, contains('404'));
  });

  test('addFromFile reads + stores + indexes', () async {
    final s = await _setup();
    final tmp = File('${s.storeDir.path}/local.m3u')..writeAsStringSync(_m3u);
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);

    final out = await ctrl.addFromFile(tmp, name: 'Local');
    expect(out.ok, isTrue);
    expect(s.c.read(userPlaylistsProvider).single.entryCount, 2);
  });

  test('remove drops the playlist and bumps version', () async {
    final s = await _setup(handler: (_) => _text(_m3u, 200));
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);
    await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
    final id = s.c.read(userPlaylistsProvider).single.id;
    final v1 = s.c.read(userPlaylistsVersionProvider);

    final out = await ctrl.remove(id);
    expect(out.ok, isTrue);
    expect(s.c.read(userPlaylistsProvider), isEmpty);
    expect(s.c.read(userPlaylistsVersionProvider), greaterThan(v1));
  });

  test('refresh re-imports, preserves id, stamps lastRefreshedAt', () async {
    var calls = 0;
    final s = await _setup(
      handler: (_) {
        calls++;
        if (calls == 1) {
          return _text('#EXTM3U\n#EXTINF:-1, One\nhttp://h/one\n', 200);
        }
        return _text(_m3u, 200);
      },
    );
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);
    await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
    final before = s.c.read(userPlaylistsProvider).single;
    expect(before.entryCount, 1);
    expect(before.lastRefreshedAt, isNull);

    final out = await ctrl.refresh(before.id);
    expect(out.ok, isTrue);
    final after = s.c.read(userPlaylistsProvider).single;
    expect(after.id, before.id);
    expect(after.entryCount, 2);
    expect(after.lastRefreshedAt, isNotNull);
  });

  test('refresh of unknown id fails cleanly', () async {
    final s = await _setup();
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);
    final out = await ctrl.refresh('does-not-exist');
    expect(out.ok, isFalse);
    expect(out.message, contains('unknown playlist'));
  });

  test('userPlaylistsProvider re-emits on version bump', () async {
    final s = await _setup(handler: (_) => _text(_m3u, 200));
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);

    final emitted = <List<UserPlaylist>>[];
    s.c.listen<List<UserPlaylist>>(
      userPlaylistsProvider,
      (_, next) => emitted.add(next),
      fireImmediately: true,
    );

    await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
    expect(emitted.last, hasLength(1));
  });

  test('re-importing the same URL dedupes in place (no duplicate)', () async {
    final s = await _setup(handler: (_) => _text(_m3u, 200));
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);

    final out1 = await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
    expect(out1.ok, isTrue);
    final firstId = s.c.read(userPlaylistsProvider).single.id;

    // Load the SAME URL again — should refresh the existing entry,
    // not append a second one.
    final out2 = await ctrl.addFromUrl('https://h/list.m3u', name: 'List');
    expect(out2.ok, isTrue);
    expect(out2.data?['deduped'], isTrue);

    final list = s.c.read(userPlaylistsProvider);
    expect(list, hasLength(1), reason: 're-import must not duplicate');
    expect(list.single.id, firstId, reason: 'id preserved across re-import');
  });

  test('re-importing the same file dedupes in place', () async {
    final s = await _setup();
    final tmp = File('${s.storeDir.path}/local.m3u')..writeAsStringSync(_m3u);
    final ctrl = s.c.read(userPlaylistControllerProvider.notifier);

    await ctrl.addFromFile(tmp, name: 'Local');
    final firstId = s.c.read(userPlaylistsProvider).single.id;

    final out2 = await ctrl.addFromFile(tmp, name: 'Local again');
    expect(out2.ok, isTrue);
    expect(out2.data?['deduped'], isTrue);

    final list = s.c.read(userPlaylistsProvider);
    expect(list, hasLength(1), reason: 'same path must dedupe');
    expect(list.single.id, firstId);
  });

  test(
    'cold boot: persisted playlists hydrate into the list + voice index',
    () async {
      // Session 1 — import + persist to disk, then "close the car".
      final s1 = await _setup(handler: (_) => _text(_m3u, 200));
      final out1 = await s1.c
          .read(userPlaylistControllerProvider.notifier)
          .addFromUrl('https://h/list.m3u', name: 'List');
      expect(out1.ok, isTrue);
      final saved = s1.c.read(userPlaylistsProvider).single;
      final savedId = saved.id;
      final stationId = saved.stations.first.id;
      s1.c.dispose();

      // Session 2 — a brand-new container over the SAME store dir.
      final s2 = await _setup(
        handler: (_) => _text(_m3u, 200),
        storeDir: s1.storeDir,
      );

      // Wait for the async disk hydration to land. userPlaylistsProvider
      // watches userPlaylistsHydratedProvider, so once it resolves the
      // list reflects the persisted set — without a mutation.
      await s2.c.read(userPlaylistsHydratedProvider.future);
      await _settle();

      final list = s2.c.read(userPlaylistsProvider);
      expect(list, hasLength(1), reason: 'persisted playlist should hydrate');
      expect(list.single.id, savedId);

      // Voice search also recovered on cold boot, no mutation needed:
      // building the controller re-indexes against the hydrated list.
      final radio = s2.c.read(radioControllerProvider.notifier);
      final play = await radio.playStationById(stationId);
      await _settle();
      expect(play.ok, isTrue);
      expect(s2.player.played.single.id, stationId);
    },
  );
}
