import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/m3u_parser.dart';
import 'package:ilink/features/radio/data/station_identity.dart';

void main() {
  group('parseM3u', () {
    test('full EXTINF: tvg-logo, group-title, bitrate, name', () {
      const m3u = '''
#EXTM3U
#PLAYLIST:Online radio: JAZZ Music (www.radio.pervii.com)
#EXTINF:-1 tvg-logo="https://img.host/logo.png" group-title="JAZZ Radio", Frequence Jazz - 128
https://jazzradio.ice.infomaniak.ch/frequencejazz-high.mp3
''';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'Frequence Jazz');
      expect(s.first.favicon, 'https://img.host/logo.png');
      expect(s.first.tags, ['JAZZ Radio']);
      expect(s.first.bitrate, 128);
      expect(
        s.first.streamUrl,
        'https://jazzradio.ice.infomaniak.ch/frequencejazz-high.mp3',
      );
      expect(
        s.first.id,
        StationIdentity.forStreamUrl(
          'https://jazzradio.ice.infomaniak.ch/frequencejazz-high.mp3',
        ),
      );
    });

    test('bare "#EXTINF:-1, Name" with no attributes', () {
      const m3u = '#EXTINF:-1, Plain Radio\nhttp://host:8000/stream';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'Plain Radio');
      expect(s.first.favicon, isNull);
      expect(s.first.tags, isEmpty);
      expect(s.first.bitrate, 0);
    });

    test('name containing " - " that is not a bitrate is preserved', () {
      const m3u = '#EXTINF:-1, Rock - The Classics\nhttp://h/s';
      expect(parseM3u(m3u).first.name, 'Rock - The Classics');
    });

    test('bitrate suffix stripped only inside the plausible band', () {
      // 9000 is out of the 32..512 band → kept as part of the name.
      const m3u =
          '#EXTINF:-1, Studio - 9000\nhttp://h/a\n'
          '#EXTINF:-1, Hi Fi - 320 kbps\nhttp://h/b';
      final s = parseM3u(m3u);
      expect(s[0].name, 'Studio - 9000');
      expect(s[0].bitrate, 0);
      expect(s[1].name, 'Hi Fi');
      expect(s[1].bitrate, 320);
    });

    test('logo/group URL containing a comma does not split the title', () {
      const m3u =
          '#EXTINF:-1 tvg-logo="https://h/l.png?a=1,2" group-title="A,B", '
          'Comma Safe\nhttp://h/s';
      final s = parseM3u(m3u).first;
      expect(s.name, 'Comma Safe');
      expect(s.favicon, 'https://h/l.png?a=1,2');
      expect(s.tags, ['A,B']);
    });

    test('CRLF line endings are handled', () {
      const m3u = '#EXTM3U\r\n#EXTINF:-1, CRLF\r\nhttp://h/s\r\n';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'CRLF');
      expect(s.first.streamUrl, 'http://h/s');
    });

    test('duplicate stream URL is deduped (first wins)', () {
      const m3u =
          '#EXTINF:-1, First\nhttp://h/s\n'
          '#EXTINF:-1, Second\nhttp://h/s';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'First');
    });

    test('EXTINF with no following URL is discarded', () {
      const m3u = '#EXTINF:-1, Orphan\n#EXTINF:-1, Real\nhttp://h/s';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'Real');
    });

    test('non-http URL (relative path) is skipped', () {
      const m3u =
          '#EXTINF:-1, Rel\n../vtuner/foo.m3u\n'
          '#EXTINF:-1, Abs\nhttps://h/s';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'Abs');
    });

    test('stray URL with no EXTINF falls back to host name', () {
      const m3u = 'http://radio.example.org:9000/live';
      final s = parseM3u(m3u);
      expect(s, hasLength(1));
      expect(s.first.name, 'radio.example.org');
    });

    test('.m3u8 stream is flagged isHls', () {
      const m3u = '#EXTINF:-1, HLS\nhttps://h/live/index.m3u8';
      expect(parseM3u(m3u).first.isHls, isTrue);
    });

    test('blank lines and unknown # directives are ignored', () {
      const m3u =
          '#EXTM3U\n\n#EXTGRP:misc\n   \n'
          '#EXTINF:-1, Clean\nhttp://h/s\n\n';
      expect(parseM3u(m3u), hasLength(1));
    });

    test('cap bounds the result and stops early', () {
      final b = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 50; i++) {
        b.writeln('#EXTINF:-1, S$i');
        b.writeln('http://h/$i');
      }
      final s = parseM3u(b.toString(), cap: 10);
      expect(s, hasLength(10));
      expect(s.first.name, 'S0');
      expect(s.last.name, 'S9');
    });

    test('empty body / non-positive cap → empty list', () {
      expect(parseM3u(''), isEmpty);
      expect(parseM3u('#EXTINF:-1, X\nhttp://h/s', cap: 0), isEmpty);
    });

    test('result list is unmodifiable', () {
      final s = parseM3u('#EXTINF:-1, X\nhttp://h/s');
      expect(() => s.clear(), throwsUnsupportedError);
    });

    test('parseM3uIsolate applies the default cap', () {
      final b = StringBuffer();
      for (var i = 0; i < kDefaultStationCap + 25; i++) {
        b.writeln('#EXTINF:-1, S$i');
        b.writeln('http://h/$i');
      }
      expect(parseM3uIsolate(b.toString()), hasLength(kDefaultStationCap));
    });
  });
}
