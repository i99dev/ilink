import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/playlists/m3u_parser.dart';

void main() {
  group('parseM3uEntries', () {
    test('parses a full IPTV entry with attributes', () {
      const body = '''
#EXTM3U
#EXTINF:-1 tvg-id="BBCNews.uk" tvg-logo="https://logo/bbc.png" group-title="News",BBC News
https://host/bbc/index.m3u8
''';
      final entries = parseM3uEntries(body);
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.name, 'BBC News');
      expect(e.tvgId, 'BBCNews.uk');
      expect(e.logo, 'https://logo/bbc.png');
      expect(e.group, 'News');
      expect(e.url, 'https://host/bbc/index.m3u8');
      expect(e.isHls, isTrue);
    });

    test('captures EXTVLCOPT referrer + user-agent for the next URL', () {
      const body = '''
#EXTINF:-1,Channel One
#EXTVLCOPT:http-referrer=https://ref.example/
#EXTVLCOPT:http-user-agent=Mozilla/5.0 (TV)
http://host/one.m3u8
''';
      final e = parseM3uEntries(body).single;
      expect(e.referrer, 'https://ref.example/');
      expect(e.userAgent, 'Mozilla/5.0 (TV)');
    });

    test('#EXTGRP supplies a group when EXTINF has none', () {
      const body = '''
#EXTINF:-1,Sky Sports
#EXTGRP:Sports
http://host/sky
''';
      expect(parseM3uEntries(body).single.group, 'Sports');
    });

    test('title is the text after the first unquoted comma', () {
      // A comma inside the logo URL must not split the title early.
      const body = '''
#EXTINF:-1 tvg-logo="https://logo/a,b.png" group-title="Movies",Action, Now
http://host/x
''';
      expect(parseM3uEntries(body).single.name, 'Action, Now');
    });

    test('dedupes by stream URL (first wins)', () {
      const body = '''
#EXTINF:-1,First
http://host/dup
#EXTINF:-1,Second
http://host/dup
''';
      final entries = parseM3uEntries(body);
      expect(entries, hasLength(1));
      expect(entries.single.name, 'First');
    });

    test('a bare URL with no EXTINF falls back to the host name', () {
      final e = parseM3uEntries('http://media.example/live').single;
      expect(e.name, 'media.example');
    });

    test('skips relative / non-http lines without throwing', () {
      const body = '''
#EXTINF:-1,Relative
/local/path.ts
#EXTINF:-1,Good
https://host/good.m3u8
''';
      final entries = parseM3uEntries(body);
      expect(entries, hasLength(1));
      expect(entries.single.name, 'Good');
    });

    test('honours the cap', () {
      final body = StringBuffer();
      for (var i = 0; i < 10; i++) {
        body.writeln('#EXTINF:-1,Ch$i');
        body.writeln('http://host/$i');
      }
      expect(parseM3uEntries(body.toString(), cap: 3), hasLength(3));
    });

    test('empty body / non-positive cap yield nothing', () {
      expect(parseM3uEntries(''), isEmpty);
      expect(parseM3uEntries('http://h/x', cap: 0), isEmpty);
    });

    test('handles CRLF line endings', () {
      const body = '#EXTINF:-1,CRLF\r\nhttp://host/crlf\r\n';
      expect(parseM3uEntries(body).single.name, 'CRLF');
    });
  });
}
