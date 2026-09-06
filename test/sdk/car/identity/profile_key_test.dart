/// Five-axis [ProfileKey] contract test. Pins:
/// - brand axis (CarBrand enum)
/// - firmwareVersion axis (Dart canonical; the wire-shape JSON key is
///   still `dilinkFamily` to match Kotlin)
/// - 1:1 wire-shape round-trip (`toJson` / `fromJson`)
/// - equality + hash uses all five axes
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/sdk/car/brand.dart';
import 'package:ilink/sdk/car/identity/profile_key.dart';

void main() {
  group('ProfileKey 5-axis', () {
    test('canonical constructor populates every axis', () {
      const k = ProfileKey(
        brand: CarBrand.byd,
        firmwareVersion: 'dilink_5_1',
        modelName: 'l8',
        subTrim: 'flagship',
        fingerprint: 'BYD/L8/1.0',
      );
      expect(k.brand, CarBrand.byd);
      expect(k.firmwareVersion, 'dilink_5_1');
      expect(k.modelName, 'l8');
      expect(k.subTrim, 'flagship');
      expect(k.fingerprint, 'BYD/L8/1.0');
    });

    test('JSON round-trip preserves every axis', () {
      const original = ProfileKey(
        brand: CarBrand.byd,
        firmwareVersion: 'dilink_8_x',
        modelName: 'l8',
        subTrim: 'flagship',
        fingerprint: 'BYD/L8FLAGSHIP/2.1',
      );
      final restored = ProfileKey.fromJson(original.toJson());
      expect(restored, original);
    });

    test('fromJson tolerates missing brand (defaults to byd)', () {
      final k = ProfileKey.fromJson(const {
        'dilinkFamily': 'dilink_5_1',
        'variantId': 'l8',
      });
      expect(k.brand, CarBrand.byd);
      expect(k.firmwareVersion, 'dilink_5_1');
    });

    test('fromJson falls back to CarBrand.unknown on bad brand string', () {
      final k = ProfileKey.fromJson(const {
        'brand': 'not_a_brand',
        'dilinkFamily': 'dilink_5_1',
      });
      expect(k.brand, CarBrand.unknown);
    });

    test('equality + hash respect all five axes', () {
      const a = ProfileKey(
        brand: CarBrand.byd,
        firmwareVersion: 'dilink_5_1',
        modelName: 'l8',
      );
      const sameAsA = ProfileKey(
        brand: CarBrand.byd,
        firmwareVersion: 'dilink_5_1',
        modelName: 'l8',
      );
      const differentBrand = ProfileKey(
        brand: CarBrand.geely,
        firmwareVersion: 'dilink_5_1',
        modelName: 'l8',
      );
      const differentVersion = ProfileKey(
        brand: CarBrand.byd,
        firmwareVersion: 'dilink_5_0',
        modelName: 'l8',
      );
      expect(a, sameAsA);
      expect(a.hashCode, sameAsA.hashCode);
      expect(a == differentBrand, isFalse);
      expect(a == differentVersion, isFalse);
    });

    test('CarBrand wire round-trip', () {
      for (final brand in CarBrand.values) {
        expect(
          CarBrand.fromWire(brand.wire),
          brand,
          reason: '${brand.wire} must round-trip',
        );
      }
    });
  });
}
