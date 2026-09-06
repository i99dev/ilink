import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI gate: Android backup must stay disabled.
///
/// `android:allowBackup` defaults to **true** when the attribute is absent, so
/// deleting the line is a silent regression rather than a build error. What it
/// costs when it regresses:
///
///   * Optional-service consent (`optional_services.v1`) is restored from a
///     previous install, so catalogs / streaming / GitHub updates come back ON
///     without the driver being asked. The Optional Services screen states they
///     are "off until you enable them"; a restore makes that untrue.
///   * flutter_secure_storage ciphertext is restored without its Keystore key
///     (the key never leaves the device), producing the runtime error
///     "Key mismatch detected during cipher initialization".
///
/// Observed on an emulator: `adb uninstall` followed by `adb install` skipped
/// onboarding entirely and every optional service was already enabled.
void main() {
  group('Android backup policy', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    test('manifest exists where this test expects it', () {
      expect(
        manifest.existsSync(),
        isTrue,
        reason: 'Run tests from the repository root.',
      );
    });

    test('allowBackup is explicitly false', () {
      final xml = manifest.readAsStringSync();
      expect(
        xml.contains('android:allowBackup="false"'),
        isTrue,
        reason:
            'android:allowBackup must be explicitly false — the attribute '
            'defaults to true when omitted, which restores optional-service '
            'consent onto a fresh install.',
      );
      expect(
        xml.contains('android:allowBackup="true"'),
        isFalse,
        reason: 'Backup must not be re-enabled.',
      );
    });

    test('device-to-device transfer is governed by extraction rules', () {
      // On API 31+ allowBackup alone does not stop D2D transfer.
      final xml = manifest.readAsStringSync();
      expect(
        xml.contains(
          'android:dataExtractionRules="@xml/data_extraction_rules"',
        ),
        isTrue,
        reason:
            'API 31+ governs device-to-device transfer through '
            'dataExtractionRules, not allowBackup.',
      );
    });

    test('extraction rules exclude every domain from both paths', () {
      final rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      expect(rules.existsSync(), isTrue);
      final xml = rules.readAsStringSync();

      expect(xml.contains('<cloud-backup>'), isTrue);
      expect(xml.contains('<device-transfer>'), isTrue);

      // Both sections must exclude the domains that can hold consent or
      // secure-storage ciphertext. Each appears once per section.
      for (final domain in ['root', 'file', 'database', 'sharedpref']) {
        expect(
          '<exclude domain="$domain" />'.allMatches(xml).length,
          2,
          reason:
              'domain "$domain" must be excluded from BOTH cloud-backup and '
              'device-transfer.',
        );
      }
    });
  });
}
