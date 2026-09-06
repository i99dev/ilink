import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/_car_domain/support/hu_vendor.dart';
import 'package:ilink/features/_car_domain/support/hu_vendor_detector.dart';

void main() {
  group('HuVendorDetector.classify — BYD positive markers', () {
    test('outswver present → byd (the strongest signal)', () {
      expect(
        HuVendorDetector.classify({
          'apps.setting.product.outswver': '34.1.17.2511242',
        }),
        HuVendor.byd,
      );
    });

    test('persist.sys.byd.default_name present → byd', () {
      expect(
        HuVendorDetector.classify({'persist.sys.byd.default_name': '豹8'}),
        HuVendor.byd,
      );
    });

    test('ro.byd.ui.splitscreen present → byd (even when blank-ish)', () {
      expect(
        HuVendorDetector.classify({'ro.byd.ui.splitscreen': '0'}),
        HuVendor.byd,
      );
    });

    test('BYD markers WIN over a non-BYD brand string', () {
      // Aftermarket vendor that overwrote brand but left BYD's
      // outswver in place. The positive marker is the truth.
      expect(
        HuVendorDetector.classify({
          'apps.setting.product.outswver': '34.1.17',
          'ro.product.brand': 'yuanfeng',
        }),
        HuVendor.byd,
      );
    });
  });

  group('HuVendorDetector.classify — brand string', () {
    test('case-insensitive byd brand → byd', () {
      expect(
        HuVendorDetector.classify({'ro.product.brand': 'BYD'}),
        HuVendor.byd,
      );
      expect(
        HuVendorDetector.classify({'ro.product.brand': 'byd'}),
        HuVendor.byd,
      );
    });

    test('every aftermarket vendor brand string resolves correctly', () {
      const cases = <String, HuVendor>{
        'Yuanfeng': HuVendor.yuanfeng,
        'YUANFENG-X1': HuVendor.yuanfeng,
        'Desay SV': HuVendor.desay,
        'Liangshan-EV': HuVendor.liangshan,
        'Shinco-Auto': HuVendor.shinco,
        'acloud': HuVendor.acloud,
        'NWD-Mini': HuVendor.nwd,
      };
      for (final entry in cases.entries) {
        expect(
          HuVendorDetector.classify({'ro.product.brand': entry.key}),
          entry.value,
          reason: 'brand=${entry.key}',
        );
      }
    });

    test('hk is matched only as a standalone token, never as substring', () {
      // Standalone — matches.
      expect(
        HuVendorDetector.classify({'ro.product.brand': 'hk'}),
        HuVendor.hk,
      );
      // Substring — must NOT match (would false-positive on hkmc,
      // hyperlink, etc.).
      expect(
        HuVendorDetector.classify({'ro.product.brand': 'hkmc'}),
        HuVendor.unknown,
      );
    });

    test('manufacturer falls back when brand is empty', () {
      expect(
        HuVendorDetector.classify({
          'ro.product.brand': '',
          'ro.product.manufacturer': 'Yuanfeng',
        }),
        HuVendor.yuanfeng,
      );
    });
  });

  group('HuVendorDetector.classify — fingerprint last-resort', () {
    test('vendor name in fingerprint is recognised', () {
      // Aftermarket build that spoofs brand/manufacturer to "BYD"
      // but leaves the build chain fingerprint alone — this is a
      // documented Yuanfeng pattern in the field.
      expect(
        HuVendorDetector.classify({
          'ro.product.brand': 'BYD',
          'ro.product.manufacturer': 'BYD',
          'ro.build.fingerprint':
              'Yuanfeng/han_l/han_l:13/TQ3A.230705.001.B4/v3.2.4:user/release-keys',
        }),
        // brand string still wins → byd. Order matters.
        HuVendor.byd,
      );
    });

    test('fingerprint catches vendor when brand + manufacturer empty', () {
      expect(
        HuVendorDetector.classify({
          'ro.product.brand': '',
          'ro.product.manufacturer': '',
          'ro.build.fingerprint':
              'Desay/sv-tang/sv-tang:13/TQ3A/v2.1:user/release-keys',
        }),
        HuVendor.desay,
      );
    });
  });

  group('HuVendorDetector.classify — unknown fallback', () {
    test('empty map → unknown', () {
      expect(HuVendorDetector.classify({}), HuVendor.unknown);
    });

    test('only generic AOSP props → unknown', () {
      expect(
        HuVendorDetector.classify({
          'ro.product.brand': 'google',
          'ro.product.manufacturer': 'Google',
          'ro.build.fingerprint': 'google/redfin/redfin:13/TQ3A/release-keys',
        }),
        HuVendor.unknown,
      );
    });

    test('null values are treated as missing', () {
      expect(
        HuVendorDetector.classify({
          'ro.product.brand': null,
          'ro.product.manufacturer': null,
          'ro.build.fingerprint': null,
        }),
        HuVendor.unknown,
      );
    });
  });
}
