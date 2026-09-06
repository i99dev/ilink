import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/app_actions/data/package_meta_reader.dart';

void main() {
  group('PackageMetaReader.parsePackageDump', () {
    test('flags SYSTEM package', () {
      const dump = '''
Package [com.android.systemui]:
  flags=[ SYSTEM HAS_CODE ALLOW_BACKUP ]
  versionName=14
  enabled=true
''';
      final m = PackageMetaReader.parsePackageDump(
        dump,
        packageName: 'com.android.systemui',
      );
      expect(m.isSystem, isTrue);
      expect(m.canUninstall, isFalse);
      expect(m.enabled, isTrue);
      expect(m.versionName, '14');
    });

    test('user app — uninstallable + enabled', () {
      const dump = '''
Package [com.example.app]:
  flags=[ HAS_CODE ALLOW_BACKUP ]
  versionName=1.2.3
  installerPackageName=com.android.vending
  enabled=true
''';
      final m = PackageMetaReader.parsePackageDump(
        dump,
        packageName: 'com.example.app',
      );
      expect(m.isSystem, isFalse);
      expect(m.canUninstall, isTrue);
      expect(m.enabled, isTrue);
      expect(m.versionName, '1.2.3');
      expect(m.installerPackage, 'com.android.vending');
    });

    test('disabled-by-user (enabled=2) reads as disabled', () {
      const dump = '''
Package [com.example.app]:
  flags=[ HAS_CODE ]
  enabled=2
''';
      final m = PackageMetaReader.parsePackageDump(
        dump,
        packageName: 'com.example.app',
      );
      expect(m.enabled, isFalse);
    });

    test('size sums codeSize + dataSize + cacheSize when present', () {
      const dump = '''
Package [com.example.app]:
  flags=[ ]
  enabled=true
  codeSize=10000
  dataSize=20000
  cacheSize=5000
''';
      final m = PackageMetaReader.parsePackageDump(
        dump,
        packageName: 'com.example.app',
      );
      expect(m.sizeBytes, 35000);
    });

    test('handles "null" version + missing installer', () {
      const dump = '''
Package [com.foo]:
  flags=[ ]
  versionName=null
  enabled=true
''';
      final m = PackageMetaReader.parsePackageDump(
        dump,
        packageName: 'com.foo',
      );
      expect(m.versionName, isNull);
      expect(m.installerPackage, isNull);
    });
  });

  group('PackageMetaReader.parseDozeWhitelist', () {
    test('extracts package names ignoring uid suffix', () {
      const dump = '''
system-excidle:
  com.android.providers.downloads,1000
  com.android.cellbroadcastreceiver,3001
user:
  com.example.foo,11020
''';
      final out = PackageMetaReader.parseDozeWhitelist(dump);
      expect(
        out,
        containsAll([
          'com.android.providers.downloads',
          'com.android.cellbroadcastreceiver',
          'com.example.foo',
        ]),
      );
    });

    test('empty input returns empty set', () {
      expect(PackageMetaReader.parseDozeWhitelist(''), isEmpty);
    });
  });

  group('PackageMetaReader.parsePackageList', () {
    test('returns enabled vs disabled based on disabled list', () {
      const thirdParty = '''
package:com.example.foo
package:com.example.bar
package:com.example.baz
''';
      const disabled = '''
package:com.example.bar
''';
      final out = PackageMetaReader.parsePackageList(
        thirdPartyOutput: thirdParty,
        disabledOutput: disabled,
      );
      expect(out.length, 3);
      final foo = out.firstWhere((e) => e.packageName == 'com.example.foo');
      final bar = out.firstWhere((e) => e.packageName == 'com.example.bar');
      expect(foo.enabled, isTrue);
      expect(bar.enabled, isFalse);
    });
  });
}
