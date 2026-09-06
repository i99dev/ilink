import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/user_playlist_store.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:ilink/features/radio/domain/user_playlist.dart';

UserPlaylist _pl(
  String name, {
  DateTime? at,
  List<Station> stations = const [],
  UserPlaylistSource? source,
}) {
  final t = at ?? DateTime.now();
  return UserPlaylist(
    id: UserPlaylist.newId(name, t),
    name: name,
    source: source ?? UserPlaylistUrlSource('https://h/$name.m3u'),
    importedAt: t,
    stations: stations,
  );
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rups_test_');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('starts empty', () async {
    final s = FileUserPlaylistStore(dir);
    await s.ready;
    expect(s.getAll(), isEmpty);
    expect(s.getById('any'), isNull);
  });

  test('save then read back via getAll + getById', () async {
    final s = FileUserPlaylistStore(dir);
    final pl = _pl('Arabic');
    await s.save(pl);

    expect(s.getAll().single.id, pl.id);
    expect(s.getById(pl.id)?.name, 'Arabic');
  });

  test('getAll is sorted most-recently-imported first', () async {
    final s = FileUserPlaylistStore(dir);
    final a = _pl('A', at: DateTime(2026, 1, 1));
    final b = _pl('B', at: DateTime(2026, 6, 1));
    final c = _pl('C', at: DateTime(2026, 3, 1));
    await s.save(a);
    await s.save(b);
    await s.save(c);

    expect(s.getAll().map((p) => p.name), ['B', 'C', 'A']);
  });

  test('save with the same id replaces', () async {
    final s = FileUserPlaylistStore(dir);
    final pl = _pl('Arabic');
    await s.save(pl);
    final refreshed = pl.withRefresh(
      at: DateTime.now(),
      stations: const [
        Station(id: 'x', sourceUuid: '', name: 'X', streamUrl: 'http://h/x'),
      ],
    );
    await s.save(refreshed);

    expect(s.getAll(), hasLength(1));
    expect(s.getById(pl.id)?.entryCount, 1);
  });

  test('remove drops from memory and disk', () async {
    final s = FileUserPlaylistStore(dir);
    final pl = _pl('Arabic');
    await s.save(pl);
    await s.remove(pl.id);
    expect(s.getById(pl.id), isNull);

    final s2 = FileUserPlaylistStore(dir);
    await s2.ready;
    expect(s2.getById(pl.id), isNull);
  });

  test('persists across instances (cross-session hydrate)', () async {
    final a = FileUserPlaylistStore(dir);
    final pl = _pl(
      'Arabic',
      source: const UserPlaylistFileSource('/sdcard/Downloads/arabic.m3u'),
      stations: const [
        Station(
          id: 's1',
          sourceUuid: '',
          name: 'DW',
          streamUrl: 'https://dw/x',
        ),
      ],
    );
    await a.save(pl);

    final b = FileUserPlaylistStore(dir);
    await b.ready;
    final got = b.getById(pl.id)!;
    expect(got.name, 'Arabic');
    expect(got.source, isA<UserPlaylistFileSource>());
    expect(got.stations.single.name, 'DW');
  });

  test('corrupt file on disk is ignored (miss, no throw)', () async {
    await File('${dir.path}/corrupt.json').writeAsString('{not json');
    final s = FileUserPlaylistStore(dir);
    await s.ready;
    expect(s.getAll(), isEmpty);
  });

  test('no .tmp file is left after save', () async {
    final s = FileUserPlaylistStore(dir);
    await s.save(_pl('A'));
    final leftovers = dir
        .listSync()
        .where((e) => e.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('live save during hydration is not clobbered by disk', () async {
    final a = FileUserPlaylistStore(dir);
    final pl = _pl('Stale');
    await a.save(pl);

    final b = FileUserPlaylistStore(dir);
    final fresh = _pl('Fresh', at: DateTime.now());
    await b.save(fresh);
    await b.ready;

    final names = b.getAll().map((p) => p.name).toSet();
    expect(names, containsAll(['Stale', 'Fresh']));
  });

  test('UserPlaylist round-trips through JSON via the store', () async {
    final s = FileUserPlaylistStore(dir);
    final at = DateTime(2026, 5, 20, 12, 30, 45);
    final pl = UserPlaylist(
      id: UserPlaylist.newId('Mix', at),
      name: 'Mix',
      source: const UserPlaylistUrlSource('https://h/list.m3u'),
      importedAt: at,
      lastRefreshedAt: at.add(const Duration(hours: 2)),
      stations: const [
        Station(
          id: 'a',
          sourceUuid: '',
          name: 'Alpha',
          streamUrl: 'http://h/a',
          favicon: 'http://h/a.png',
          tags: ['arabic', 'news'],
          bitrate: 128,
        ),
      ],
    );
    await s.save(pl);

    final reread = FileUserPlaylistStore(dir);
    await reread.ready;
    final got = reread.getById(pl.id)!;
    expect(got.toJson(), jsonDecode(jsonEncode(pl.toJson())));
  });
}
