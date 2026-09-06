import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/mini_app_bridge_config.dart';

/// Cross-repo grammar + CSP + egress-gate tests. The origin corpus is the
/// vendored copy of the SDK's `origin-fixtures.json`; asserting the Dart
/// `normalizeMiniAppOrigin` against it proves the three validators (SDK zod,
/// backend Pydantic, car Dart) cannot silently drift.
void main() {
  final fixtures =
      jsonDecode(
            File(
              'test/features/mini_apps/origin_fixtures.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  group('normalizeMiniAppOrigin — shared grammar', () {
    for (final entry
        in (fixtures['valid'] as List).cast<Map<String, dynamic>>()) {
      test('accepts ${entry['input']} -> ${entry['canonical']}', () {
        expect(
          normalizeMiniAppOrigin(entry['input'] as String),
          entry['canonical'],
        );
      });
    }
    for (final bad in (fixtures['invalid'] as List).cast<String>()) {
      test('rejects ${jsonEncode(bad)}', () {
        expect(normalizeMiniAppOrigin(bad), isNull);
      });
    }

    test('strips default :443, keeps non-default port', () {
      expect(normalizeMiniAppOrigin('https://x.com:443'), 'https://x.com');
      expect(
        normalizeMiniAppOrigin('https://x.com:8443'),
        'https://x.com:8443',
      );
    });
  });

  group('isAllowedMiniAppOriginForApp', () {
    const app = ['https://api.aladhan.com'];

    test('rejects retired hosting even when declared by an old bundle', () {
      // The retired i99dash hosting, deliberately not an iLINK host: an old
      // bundle declaring the dead origin must still be refused, because that
      // DNS no longer belongs to this project.
      expect(
        isAllowedMiniAppOriginForApp(
          Uri.parse('https://miniapps.i99dash.app/x'),
          const ['https://miniapps.i99dash.app'],
        ),
        isFalse,
      );
    });
    test('allows a declared origin (ignoring path/query)', () {
      expect(
        isAllowedMiniAppOriginForApp(
          Uri.parse('https://api.aladhan.com/v1/calendar?x=1'),
          app,
        ),
        isTrue,
      );
    });
    test('blocks an undeclared origin', () {
      expect(
        isAllowedMiniAppOriginForApp(
          Uri.parse('https://evil.example.com/exfil'),
          app,
        ),
        isFalse,
      );
    });
    test('blocks http even if host matches', () {
      expect(
        isAllowedMiniAppOriginForApp(Uri.parse('http://api.aladhan.com'), app),
        isFalse,
      );
    });
  });

  group('isAllowedMiniAppRequest — primary egress gate', () {
    const app = ['https://api.aladhan.com'];

    test('bundle-local schemes always pass', () {
      for (final u in [
        'file:///data/app/index.html',
        'data:text/css,x',
        'blob:abc',
        'about:blank',
      ]) {
        expect(
          isAllowedMiniAppRequest(Uri.parse(u), const []),
          isTrue,
          reason: u,
        );
      }
    });
    test('declared https + its wss form pass', () {
      expect(
        isAllowedMiniAppRequest(Uri.parse('https://api.aladhan.com/v1/x'), app),
        isTrue,
      );
      expect(
        isAllowedMiniAppRequest(Uri.parse('wss://api.aladhan.com/socket'), app),
        isTrue,
      );
    });
    test('undeclared https + plain ws + http are blocked', () {
      expect(
        isAllowedMiniAppRequest(Uri.parse('https://evil.com/x'), app),
        isFalse,
      );
      expect(
        isAllowedMiniAppRequest(Uri.parse('wss://evil.com/x'), app),
        isFalse,
      );
      expect(
        isAllowedMiniAppRequest(Uri.parse('ws://api.aladhan.com/x'), app),
        isFalse,
      );
      expect(
        isAllowedMiniAppRequest(Uri.parse('http://api.aladhan.com/x'), app),
        isFalse,
      );
    });
  });

  group('buildMiniAppCsp', () {
    test(
      'pins every exfil directive and includes declared origin + wss form',
      () {
        final csp = buildMiniAppCsp(const ['https://api.aladhan.com']);
        // Every directive present.
        for (final d in [
          'default-src ',
          'connect-src ',
          'img-src ',
          'media-src ',
          'font-src ',
          'style-src ',
          'script-src ',
          'worker-src ',
          'child-src ',
          'frame-src ',
          'manifest-src ',
          'base-uri ',
          'form-action ',
          'frame-ancestors ',
          'object-src ',
        ]) {
          expect(csp.contains(d), isTrue, reason: 'missing directive: $d');
        }
        // connect-src carries the declared origin AND its wss form + global.
        expect(csp.contains('connect-src '), isTrue);
        expect(csp.contains('https://api.aladhan.com'), isTrue);
        expect(csp.contains('wss://api.aladhan.com'), isTrue);
        expect(csp.contains('https://miniapps.i99dash.app'), isFalse);
        // Hard pins.
        expect(csp.contains("base-uri 'self'"), isTrue);
        expect(csp.contains("object-src 'none'"), isTrue);
        expect(csp.contains("frame-ancestors 'none'"), isTrue);
        // img-src must NOT be the wide `https:` source.
        expect(csp.contains('img-src https:'), isFalse);
      },
    );

    test('an undeclared origin never appears in the policy', () {
      final csp = buildMiniAppCsp(const ['https://api.aladhan.com']);
      expect(csp.contains('evil.com'), isFalse);
    });
  });
}
