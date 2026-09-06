import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/station_identity.dart';

void main() {
  group('StationIdentity.forStreamUrl', () {
    // GOLDEN. These literals pin the hash algorithm forever. If a change
    // makes this test fail, it means every persisted favourite on every
    // installed app would be orphaned — do NOT update the expected value
    // to make it pass; revert the algorithm change instead.
    test('is the SHA-1 hex of the UTF-8 URL (pinned)', () {
      expect(
        StationIdentity.forStreamUrl('http://example.com/stream'),
        '0bee5d485b67f40045d684722f4b15cbf9bec87d',
      );
      expect(
        StationIdentity.forStreamUrl(
          'https://jazzradio.ice.infomaniak.ch/frequencejazz-high.mp3',
        ),
        'b6cde89fcf4b7ded15c941e85b4c8279657cbd42',
      );
    });

    test('is deterministic across calls', () {
      const url = 'https://host.tld/path?bitrate=128';
      expect(
        StationIdentity.forStreamUrl(url),
        StationIdentity.forStreamUrl(url),
      );
    });

    test('trims surrounding whitespace only', () {
      expect(
        StationIdentity.forStreamUrl('  http://example.com/stream\n'),
        '0bee5d485b67f40045d684722f4b15cbf9bec87d',
      );
    });

    test('query-string / trailing-slash differences are distinct ids', () {
      final a = StationIdentity.forStreamUrl('http://h/s');
      final b = StationIdentity.forStreamUrl('http://h/s/');
      final c = StationIdentity.forStreamUrl('http://h/s?x=1');
      expect({a, b, c}.length, 3);
    });

    test('empty / blank URL yields empty id (rejected upstream)', () {
      expect(StationIdentity.forStreamUrl(''), '');
      expect(StationIdentity.forStreamUrl('   '), '');
    });
  });
}
