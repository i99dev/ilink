import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/station_identity.dart';
import 'package:ilink/kernel/playlists/media_identity.dart';

void main() {
  group('MediaIdentity.forStreamUrl', () {
    // GOLDEN — pins the hash algorithm forever. A change here orphans every
    // persisted favourite on every installed app. Revert the algorithm
    // change rather than updating the expected value.
    test('is the SHA-1 hex of the UTF-8 URL (pinned)', () {
      expect(
        MediaIdentity.forStreamUrl('http://example.com/stream'),
        '0bee5d485b67f40045d684722f4b15cbf9bec87d',
      );
    });

    test('deterministic across calls', () {
      const url = 'https://host.tld/index.m3u8?bitrate=hi';
      expect(MediaIdentity.forStreamUrl(url), MediaIdentity.forStreamUrl(url));
    });

    test('trims surrounding whitespace only', () {
      expect(
        MediaIdentity.forStreamUrl('  http://example.com/stream\n'),
        '0bee5d485b67f40045d684722f4b15cbf9bec87d',
      );
    });

    test('query-string / trailing-slash differences are distinct ids', () {
      final a = MediaIdentity.forStreamUrl('http://h/s');
      final b = MediaIdentity.forStreamUrl('http://h/s/');
      final c = MediaIdentity.forStreamUrl('http://h/s?x=1');
      expect({a, b, c}.length, 3);
    });

    test('empty / blank URL yields empty id', () {
      expect(MediaIdentity.forStreamUrl(''), '');
      expect(MediaIdentity.forStreamUrl('   '), '');
    });

    // The whole point of centralising in kernel: radio + TV must derive the
    // same id for the same stream, so a stream that is both a radio station
    // and a TV channel never gets two identities.
    test('agrees with radio StationIdentity (shared algorithm)', () {
      const url = 'https://cdn.example/live/index.m3u8';
      expect(
        MediaIdentity.forStreamUrl(url),
        StationIdentity.forStreamUrl(url),
      );
    });
  });
}
