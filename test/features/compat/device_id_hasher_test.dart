import 'package:ilink/features/compat/data/device_id_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceIdHasher', () {
    test('null / empty in → null out', () {
      expect(DeviceIdHasher.hash(null), isNull);
      expect(DeviceIdHasher.hash(''), isNull);
    });

    test('same VIN → same 16-char hash (deterministic across calls)', () {
      const deviceId = 'LGXC16AF8P0201234';
      final a = DeviceIdHasher.hash(deviceId);
      final b = DeviceIdHasher.hash(deviceId);
      expect(a, isNotNull);
      expect(a, equals(b));
      expect(a!.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    });

    test('different VINs → different hashes', () {
      final a = DeviceIdHasher.hash('LGXC16AF8P0201234');
      final b = DeviceIdHasher.hash('LGXC16AF8P0209999');
      expect(a, isNot(equals(b)));
    });
  });
}
