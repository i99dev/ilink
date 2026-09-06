import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tv/domain/channel.dart';
import 'package:ilink/kernel/playlists/m3u_entry.dart';
import 'package:ilink/kernel/playlists/media_identity.dart';

void main() {
  group('Channel.fromCatalogJson', () {
    test('maps the iptv-rest-api shard shape', () {
      final c = Channel.fromCatalogJson({
        'id': 'AjmanTV.ae',
        'name': 'Ajman TV',
        'url': 'https://cdn/ajman/playlist.m3u8',
        'logo': 'https://logo/ajman.png',
        'country': 'AE',
        'categories': ['general'],
        'quality': '1080p',
      });
      expect(c.name, 'Ajman TV');
      expect(c.tvgId, 'AjmanTV.ae');
      expect(c.streamUrl, 'https://cdn/ajman/playlist.m3u8');
      expect(c.country, 'AE');
      expect(c.categories, ['general']);
      expect(c.quality, '1080p');
      expect(c.isHls, isTrue);
      // identity is the SHA-1 of the URL, not the tvg-id.
      expect(c.id, MediaIdentity.forStreamUrl(c.streamUrl));
    });

    test('lifts headers into referrer/userAgent + httpHeaders', () {
      final c = Channel.fromCatalogJson({
        'id': 'X.us',
        'name': 'X',
        'url': 'http://h/x.m3u8',
        'headers': {'referrer': 'https://ref/', 'userAgent': 'UA/1'},
      });
      expect(c.referrer, 'https://ref/');
      expect(c.userAgent, 'UA/1');
      expect(c.httpHeaders, {'Referer': 'https://ref/', 'User-Agent': 'UA/1'});
    });

    test('httpHeaders is empty when no headers are set', () {
      final c = Channel.fromCatalogJson({'name': 'X', 'url': 'http://h/x'});
      expect(c.httpHeaders, isEmpty);
    });
  });

  test('Channel.fromM3uEntry maps a parsed entry', () {
    const e = M3uEntry(
      url: 'http://h/m.m3u8',
      name: 'M',
      tvgId: 'M.tv',
      logo: 'http://logo/m.png',
      group: 'Movies',
      referrer: 'http://ref/',
    );
    final c = Channel.fromM3uEntry(e);
    expect(c.name, 'M');
    expect(c.tvgId, 'M.tv');
    expect(c.group, 'Movies');
    expect(c.categories, ['Movies']);
    expect(c.referrer, 'http://ref/');
    expect(c.id, MediaIdentity.forStreamUrl('http://h/m.m3u8'));
  });

  test('toJson/fromJson round-trips', () {
    final c = Channel.fromCatalogJson({
      'id': 'R.uk',
      'name': 'Round Trip',
      'url': 'https://h/r.m3u8',
      'logo': 'https://logo/r.png',
      'country': 'GB',
      'categories': ['news', 'general'],
      'quality': '720p',
      'headers': {'referrer': 'https://ref/'},
    });
    final back = Channel.fromJson(c.toJson());
    expect(back.id, c.id);
    expect(back.name, c.name);
    expect(back.streamUrl, c.streamUrl);
    expect(back.categories, c.categories);
    expect(back.referrer, c.referrer);
    expect(back.quality, c.quality);
  });

  test('equality is identity-based via id', () {
    final a = Channel.fromCatalogJson({'name': 'A', 'url': 'http://h/same'});
    final b = Channel.fromCatalogJson({'name': 'B', 'url': 'http://h/same'});
    final d = Channel.fromCatalogJson({'name': 'A', 'url': 'http://h/other'});
    expect(a, equals(b)); // same URL → same id → equal
    expect(a, isNot(equals(d)));
  });
}
