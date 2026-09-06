import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/domain/curated_playlist.dart';
import 'package:ilink/features/radio/domain/radio_facet.dart';

CuratedIndexEntry _e(String name) => CuratedIndexEntry(
  id: name.toLowerCase(),
  name: name,
  count: 1,
  urlPath: 'p',
);

void main() {
  group('RadioFacet.split', () {
    test('parses each known prefix into (facet, stripped value)', () {
      expect(RadioFacet.split('Category: Jazz'), (RadioFacet.category, 'Jazz'));
      expect(RadioFacet.split('Country: France'), (
        RadioFacet.country,
        'France',
      ));
      expect(RadioFacet.split('Language: Arabic'), (
        RadioFacet.language,
        'Arabic',
      ));
    });

    test(
      'values containing ": " keep everything after the first separator',
      () {
        expect(RadioFacet.split('Country: Korea: South'), (
          RadioFacet.country,
          'Korea: South',
        ));
      },
    );

    test('unknown or absent prefix falls back to (other, original)', () {
      expect(RadioFacet.split('Arabic'), (RadioFacet.other, 'Arabic'));
      expect(RadioFacet.split('Genre: Pop'), (RadioFacet.other, 'Genre: Pop'));
      expect(RadioFacet.split(''), (RadioFacet.other, ''));
    });
  });

  group('CuratedIndexEntry facet/label getters', () {
    test('expose parsed facet and stripped label', () {
      final e = _e('Country: France');
      expect(e.facet, RadioFacet.country);
      expect(e.label, 'France');
      expect(e.name, 'Country: France'); // raw name untouched (stable id/key)
      expect(e.id, 'country: france');
    });
  });

  group('CuratedIndex.facetGroups', () {
    test('buckets entries by facet, in order, counting each', () {
      final idx = CuratedIndex(
        generatedAt: DateTime(2026),
        entries: [
          _e('Language: Arabic'),
          _e('Category: Jazz'),
          _e('Country: France'),
          _e('Category: Rock'),
          _e('Country: Germany'),
        ],
      );
      final groups = idx.facetGroups();
      // Category, Country, Language order (RadioFacet.order); no empty facets.
      expect(groups.map((g) => g.facet), [
        RadioFacet.category,
        RadioFacet.country,
        RadioFacet.language,
      ]);
      expect(groups.map((g) => g.count), [2, 2, 1]);
      // Within-group order preserved.
      expect(groups.first.entries.map((e) => e.label), ['Jazz', 'Rock']);
    });

    test('omits facets with no entries', () {
      final idx = CuratedIndex(
        generatedAt: DateTime(2026),
        entries: [_e('Country: France')],
      );
      expect(idx.facetGroups().map((g) => g.facet), [RadioFacet.country]);
    });
  });
}
