import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/state/m3u_link_handler.dart';

/// Match-predicate unit tests for the deep-link handler. open() is
/// exercised end-to-end during the Phase 6 on-car install (it touches
/// BuildContext + multiple providers and is integration-shaped); the
/// match() function is pure and the place behavioural drift would
/// silently steal another feature's URL.
void main() {
  const handler = M3uPlaylistLinkHandler();

  group('match — positive cases', () {
    test('file:// with .m3u extension', () {
      expect(
        handler.match(Uri.parse('file:///sdcard/Downloads/arabic.m3u')),
        'file:///sdcard/Downloads/arabic.m3u',
      );
    });
    test('file:// with .m3u8 extension', () {
      expect(handler.match(Uri.parse('file:///x/y.m3u8')), isNotNull);
    });
    test('https:// with .m3u extension', () {
      expect(
        handler.match(Uri.parse('https://h/list.m3u')),
        'https://h/list.m3u',
      );
    });
    test('http:// with .m3u8', () {
      expect(handler.match(Uri.parse('http://h/live.m3u8')), isNotNull);
    });
    test('content:// is accepted regardless of path', () {
      expect(
        handler.match(Uri.parse('content://media/external/file/42')),
        'content://media/external/file/42',
      );
    });
    test('uppercase extension still matches (case-insensitive)', () {
      expect(handler.match(Uri.parse('file:///A.M3U')), isNotNull);
    });
  });

  group('match — negative cases', () {
    test('https without an m3u extension is rejected (don\'t steal links)', () {
      expect(handler.match(Uri.parse('https://h/page')), isNull);
      expect(
        handler.match(Uri.parse('https://app.i99dash.com/m/foo')),
        isNull,
        reason: 'mini-app deep links must NOT be intercepted',
      );
    });
    test('file with non-m3u extension is rejected', () {
      expect(handler.match(Uri.parse('file:///x/y.mp3')), isNull);
      expect(handler.match(Uri.parse('file:///x/y')), isNull);
    });
    test('unknown scheme is rejected', () {
      expect(handler.match(Uri.parse('mailto:x@y.z')), isNull);
      expect(handler.match(Uri.parse('car-ilink://mini-app/foo')), isNull);
    });
    test('empty / scheme-only URI is rejected', () {
      expect(handler.match(Uri.parse('file://')), isNull);
    });
  });
}
