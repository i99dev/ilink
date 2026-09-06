import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/curated_cache.dart';
import 'package:ilink/features/radio/domain/curated_playlist.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _entry = CuratedIndexEntry(
  id: 'arabic',
  name: 'Arabic',
  count: 3,
  urlPath: 'api/playlists/arabic.json',
);

CuratedIndex _idx() =>
    CuratedIndex(generatedAt: DateTime(2026, 1, 1), entries: const [_entry]);

CuratedPlaylist _pl() => const CuratedPlaylist(
  id: 'arabic',
  name: 'Arabic',
  stations: [
    Station(id: 'a', sourceUuid: '', name: 'A', streamUrl: 'http://h/a'),
  ],
);

Future<CuratedCache> _cache({Map<String, Object>? seed}) async {
  SharedPreferences.setMockInitialValues(seed ?? const {});
  return CuratedCache(await SharedPreferences.getInstance());
}

void main() {
  test('empty cache returns null', () async {
    final c = await _cache();
    expect(c.readIndex(), isNull);
    expect(c.readPlaylist('arabic'), isNull);
  });

  test('writeIndex then readIndex round-trips', () async {
    final c = await _cache();
    await c.writeIndex(_idx());
    final read = c.readIndex()!;
    expect(read.entries.single.name, 'Arabic');
    expect(read.entries.single.id, 'arabic');
    expect(read.entries.single.count, 3);
  });

  test('writePlaylist then readPlaylist round-trips with stations', () async {
    final c = await _cache();
    await c.writePlaylist(_pl());
    final read = c.readPlaylist('arabic')!;
    expect(read.name, 'Arabic');
    expect(read.stations.single.streamUrl, 'http://h/a');
  });

  test('corrupted entry → cache miss (null), no throw', () async {
    final c = await _cache(seed: {'radio.curated.index.v1': 'not json'});
    expect(c.readIndex(), isNull);
  });

  test('clear() wipes index AND every cached playlist', () async {
    final c = await _cache();
    await c.writeIndex(_idx());
    await c.writePlaylist(_pl());
    await c.writePlaylist(
      const CuratedPlaylist(id: 'jazz', name: 'Jazz', stations: []),
    );

    await c.clear();

    expect(c.readIndex(), isNull);
    expect(c.readPlaylist('arabic'), isNull);
    expect(c.readPlaylist('jazz'), isNull);
  });

  test('persists across instances (same prefs)', () async {
    final c1 = await _cache();
    await c1.writeIndex(_idx());
    await c1.writePlaylist(_pl());

    // Fresh CuratedCache against the same SharedPreferences singleton.
    final c2 = CuratedCache(await SharedPreferences.getInstance());
    expect(c2.readIndex()?.entries, hasLength(1));
    expect(c2.readPlaylist('arabic')?.stations, hasLength(1));
  });
}
