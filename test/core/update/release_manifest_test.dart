import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/update/models/release_manifest.dart';

ReleaseManifest _manifest({
  int versionCode = 200,
  bool forceUpdate = false,
  int? minSupportedVersionCode,
}) => ReleaseManifest(
  versionCode: versionCode,
  versionName: '1.0.0+$versionCode',
  apkUrl: 'https://example.com/app.apk',
  sha256: 'abc123',
  sizeBytes: 50000000,
  signerSha256: 'def456',
  forceUpdate: forceUpdate,
  releasedAt: DateTime.utc(2026),
  minSupportedVersionCode: minSupportedVersionCode,
);

void main() {
  group('ReleaseManifest.isNewerThan', () {
    test('returns true when manifest versionCode is higher', () {
      expect(_manifest(versionCode: 200).isNewerThan(100), isTrue);
    });

    test('returns false when installed version matches manifest', () {
      expect(_manifest(versionCode: 100).isNewerThan(100), isFalse);
    });

    test('returns false when installed version is ahead', () {
      expect(_manifest(versionCode: 100).isNewerThan(200), isFalse);
    });
  });

  group('ReleaseManifest.requiresForceUpdate', () {
    test('returns true when forceUpdate flag is set', () {
      expect(_manifest(forceUpdate: true).requiresForceUpdate(150), isTrue);
    });

    test(
      'returns true when installed version is below minSupportedVersionCode',
      () {
        expect(
          _manifest(minSupportedVersionCode: 100).requiresForceUpdate(99),
          isTrue,
        );
      },
    );

    test(
      'returns false when installed version meets minSupportedVersionCode',
      () {
        expect(
          _manifest(minSupportedVersionCode: 100).requiresForceUpdate(100),
          isFalse,
        );
      },
    );

    test('returns false when neither force flag nor floor applies', () {
      expect(_manifest().requiresForceUpdate(150), isFalse);
    });
  });

  group('ReleaseManifest.fromJson', () {
    test('parses all required fields correctly', () {
      final json = {
        'versionCode': 142,
        'versionName': '0.1.0-b+142',
        'apkUrl': 'https://cdn.example.com/app.apk',
        'sha256':
            '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
        'sizeBytes': 48372910,
        'signerSha256': 'AB:CD:EF',
        'forceUpdate': false,
        'releasedAt': '2026-04-30T10:00:00Z',
        'minSupportedVersionCode': 130,
        'releaseNotes': 'Bug fixes.',
      };
      final m = ReleaseManifest.fromJson(json);
      expect(m.versionCode, 142);
      expect(m.versionName, '0.1.0-b+142');
      expect(m.minSupportedVersionCode, 130);
      expect(m.releaseNotes, 'Bug fixes.');
    });
  });
}
