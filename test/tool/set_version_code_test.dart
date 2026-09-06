import 'package:flutter_test/flutter_test.dart';

import '../../tool/set_version_code.dart';

void main() {
  group('deriveVersionCode', () {
    test('orders with SemVer', () {
      expect(deriveVersionCode('3.22.0'), 3022000);
      expect(deriveVersionCode('3.23.0'), 3023000);
      expect(deriveVersionCode('4.0.0'), 4000000);
      expect(deriveVersionCode('1.0.0'), 1000000);
    });

    test('ignores the pre-release suffix and existing build metadata', () {
      expect(deriveVersionCode('3.22.0-b'), 3022000);
      expect(deriveVersionCode('3.22.0-b+10000'), 3022000);
      expect(deriveVersionCode('3.22.0+999'), 3022000);
    });

    test('every SemVer bump strictly increases the code', () {
      // The invariant Android enforces on updates, and the reason release #2
      // failed before this existed.
      final ordered = [
        '0.1.0',
        '1.0.0',
        '3.21.9',
        '3.22.0',
        '3.22.1',
        '3.23.0',
        '4.0.0',
      ];
      final codes = ordered.map(deriveVersionCode).toList();
      for (var i = 1; i < codes.length; i++) {
        expect(
          codes[i],
          greaterThan(codes[i - 1]),
          reason: '${ordered[i]} must outrank ${ordered[i - 1]}',
        );
      }
    });

    test('stays inside the Android ceiling', () {
      expect(
        deriveVersionCode('2099.999.999'),
        lessThan(maxAndroidVersionCode),
      );
    });

    test('rejects versions this scheme cannot order', () {
      expect(() => deriveVersionCode('3.22'), throwsA(isA<VersionCodeError>()));
      expect(
        () => deriveVersionCode('3.22.0.1'),
        throwsA(isA<VersionCodeError>()),
      );
      expect(
        () => deriveVersionCode('x.y.z'),
        throwsA(isA<VersionCodeError>()),
      );
      // Would silently reorder releases: 3.1000.0 and 4.0.0 both hit 4000000.
      expect(
        () => deriveVersionCode('3.1000.0'),
        throwsA(isA<VersionCodeError>()),
      );
    });
  });

  group('applyVersionCode', () {
    test('replaces stale build metadata that release-please left behind', () {
      final out = applyVersionCode('name: ilink\nversion: 3.23.0-b+10000\n');
      expect(out, contains('version: 3.23.0-b+3023000'));
      expect(out, contains('name: ilink'));
    });

    test('adds metadata when the version has none', () {
      expect(
        applyVersionCode('version: 4.0.0\n'),
        contains('version: 4.0.0+4000000'),
      );
    });

    test('returns null when already correct, so CI makes no commit', () {
      expect(applyVersionCode('version: 3.22.0-b+3022000\n'), isNull);
    });

    test('leaves the rest of the pubspec untouched', () {
      const pubspec =
          'name: ilink\n'
          'version: 1.2.3+1\n'
          'environment:\n'
          '  sdk: ^3.0.0\n';
      final out = applyVersionCode(pubspec)!;
      expect(
        out,
        'name: ilink\nversion: 1.2.3+1002003\nenvironment:\n  sdk: ^3.0.0\n',
      );
    });

    test('fails loudly on a pubspec with no version line', () {
      expect(
        () => applyVersionCode('name: ilink\n'),
        throwsA(isA<VersionCodeError>()),
      );
    });
  });
}
