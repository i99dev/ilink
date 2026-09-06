import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/domain/curated_playlist.dart';
import 'package:ilink/features/radio/domain/station.dart';

CuratedIndexEntry _entry(String name) => CuratedIndexEntry(
  id: name.toLowerCase(),
  name: name,
  count: 1,
  urlPath: 'p',
);

Station _st(String name) => Station(
  id: name,
  sourceUuid: name,
  name: name,
  streamUrl: 'http://x/$name',
);

void main() {
  // Names follow the catalogue's "<Facet>: <Value>" shape; `label` is the
  // value the user actually says.
  final index = CuratedIndex(
    generatedAt: DateTime(2026),
    entries: [
      _entry('Category: Jazz'),
      _entry('Country: France'),
      _entry('Language: Arabic'),
      _entry('Category: News'),
    ],
  );

  group('matchCuratedEntry (voice "play …" → playlist)', () {
    test('exact facet value', () {
      expect(matchCuratedEntry(index, 'jazz')?.name, 'Category: Jazz');
      expect(matchCuratedEntry(index, 'France')?.name, 'Country: France');
    });

    test('case-insensitive + substring', () {
      expect(matchCuratedEntry(index, 'arab')?.name, 'Language: Arabic');
      expect(matchCuratedEntry(index, 'news')?.name, 'Category: News');
    });

    test('no match → null', () {
      expect(matchCuratedEntry(index, 'klingon polka'), isNull);
      expect(matchCuratedEntry(index, '   '), isNull);
    });
  });

  group('pickCuratedStation', () {
    final pl = CuratedPlaylist(
      id: 'jazz',
      name: 'Category: Jazz',
      stations: [_st('Smooth FM'), _st('Blue Note Radio'), _st('Cool Jazz')],
    );

    test('prefers a station whose name matches the query', () {
      expect(pickCuratedStation(pl, 'blue note')?.name, 'Blue Note Radio');
    });

    test('falls back to the first station when nothing matches the query', () {
      expect(pickCuratedStation(pl, 'no such station')?.name, 'Smooth FM');
      expect(pickCuratedStation(pl, '')?.name, 'Smooth FM');
    });

    test('empty playlist → null', () {
      const empty = CuratedPlaylist(id: 'e', name: 'e', stations: []);
      expect(pickCuratedStation(empty, 'anything'), isNull);
    });
  });
}
