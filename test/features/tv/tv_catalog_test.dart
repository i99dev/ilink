import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tv/domain/tv_catalog.dart';

void main() {
  group('TvCatalogGroup', () {
    test('country group keys on code; id is kind:key', () {
      final g = TvCatalogGroup.fromJson({
        'kind': 'country',
        'code': 'AE',
        'name': 'United Arab Emirates',
        'flag': '🇦🇪',
        'count': 38,
        'path': 'channels/country/ae.json',
      });
      expect(g.kind, 'country');
      expect(g.key, 'AE');
      expect(g.id, 'country:AE');
      expect(g.flag, '🇦🇪');
      expect(g.path, 'channels/country/ae.json');
    });

    test('category group keys on id', () {
      final g = TvCatalogGroup.fromJson({
        'kind': 'category',
        'id': 'news',
        'name': 'News',
        'count': 200,
        'path': 'channels/category/news.json',
      });
      expect(g.key, 'news');
      expect(g.id, 'category:news');
    });

    test('toJson round-trips both kinds', () {
      final country = TvCatalogGroup.fromJson({
        'kind': 'country',
        'code': 'GB',
        'name': 'United Kingdom',
        'count': 10,
        'path': 'channels/country/gb.json',
      });
      final back = TvCatalogGroup.fromJson(country.toJson());
      expect(back.id, country.id);
      expect(back.path, country.path);
    });
  });

  test('TvCatalogIndex splits countries and categories', () {
    final index = TvCatalogIndex.fromJson({
      'generatedAt': '2026-05-21T03:13:54Z',
      'groups': [
        {
          'kind': 'country',
          'code': 'AE',
          'name': 'UAE',
          'count': 1,
          'path': 'a',
        },
        {
          'kind': 'category',
          'id': 'news',
          'name': 'News',
          'count': 2,
          'path': 'b',
        },
        {
          'kind': 'country',
          'code': 'US',
          'name': 'USA',
          'count': 3,
          'path': 'c',
        },
        // dropped: no path
        {'kind': 'country', 'code': 'ZZ', 'name': 'Bad', 'count': 0},
      ],
    });
    expect(index.groups, hasLength(3));
    expect(index.countries.map((g) => g.key), ['AE', 'US']);
    expect(index.categories.map((g) => g.key), ['news']);
    expect(index.generatedAt.year, 2026);
  });

  test('TvChannelGroup round-trips through JSON', () {
    final group = TvChannelGroup.fromJson({
      'id': 'country:ae',
      'name': 'UAE',
      'channels': [
        {'id': 'h1', 'name': 'One', 'stream_url': 'http://h/1'},
        {'id': 'h2', 'name': 'Two', 'stream_url': 'http://h/2'},
      ],
    });
    expect(group.channelCount, 2);
    final back = TvChannelGroup.fromJson(group.toJson());
    expect(back.id, 'country:ae');
    expect(back.channels.map((c) => c.name), ['One', 'Two']);
  });
}
