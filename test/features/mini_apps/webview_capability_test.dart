import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/runtime/webview_capability.dart';

void main() {
  group('chromiumMajorFromVersionName', () {
    test('parses the leading major from a full version', () {
      expect(chromiumMajorFromVersionName('95.0.4638.74'), 95);
      expect(chromiumMajorFromVersionName('109.0.5414.118'), 109);
      expect(chromiumMajorFromVersionName('80'), 80);
    });

    test('trims surrounding whitespace', () {
      expect(chromiumMajorFromVersionName('  95.0.4638.74 '), 95);
    });

    test('null / empty / garbage → null', () {
      expect(chromiumMajorFromVersionName(null), isNull);
      expect(chromiumMajorFromVersionName(''), isNull);
      expect(chromiumMajorFromVersionName('   '), isNull);
      expect(chromiumMajorFromVersionName('Chrome'), isNull);
      expect(chromiumMajorFromVersionName('.0.1'), isNull);
    });
  });

  group('modernWebviewFromChromiumMajor', () {
    test('at/above the ES-module floor ⇒ true', () {
      expect(modernWebviewFromChromiumMajor(kEsModuleChromiumFloor), isTrue);
      expect(modernWebviewFromChromiumMajor(95), isTrue); // Di5.0 fleet
      expect(modernWebviewFromChromiumMajor(120), isTrue);
    });

    test('below the floor ⇒ false (measured-old, not null)', () {
      expect(
        modernWebviewFromChromiumMajor(kEsModuleChromiumFloor - 1),
        isFalse,
      );
      expect(modernWebviewFromChromiumMajor(79), isFalse);
    });

    test('unmeasurable (null) ⇒ null so callers fall back / fail closed', () {
      expect(modernWebviewFromChromiumMajor(null), isNull);
    });
  });

  test('floor is the conservative ES-module value', () {
    // Guards against an accidental bump back to a Chrome-100 proxy or
    // down to the unsafe 61 baseline.
    expect(kEsModuleChromiumFloor, 85);
  });
}
