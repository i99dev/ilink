import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/car/identity/car_device_id.dart';

void main() {
  group('CarDeviceId.brandOf', () {
    test('returns the brand segment of a prefixed id', () {
      expect(CarDeviceId.brandOf('byd:E51DB8F5AE5E3713'), 'byd');
      expect(CarDeviceId.brandOf('denza:ABC123'), 'denza');
    });
    test(
      'falls back to default brand for empty / un-prefixed / leading-colon',
      () {
        expect(CarDeviceId.brandOf(''), 'byd');
        expect(CarDeviceId.brandOf('E51DB8F5AE5E3713'), 'byd');
        expect(CarDeviceId.brandOf(':E51DB8F5AE5E3713'), 'byd');
      },
    );
  });

  group('CarDeviceId.nativeOf', () {
    test('returns the part after the prefix', () {
      expect(CarDeviceId.nativeOf('byd:E51DB8F5AE5E3713'), 'E51DB8F5AE5E3713');
    });
    test(
      'returns the whole string when un-prefixed / leading-colon / empty',
      () {
        expect(CarDeviceId.nativeOf('E51DB8F5AE5E3713'), 'E51DB8F5AE5E3713');
        expect(CarDeviceId.nativeOf(':E51DB8F5AE5E3713'), ':E51DB8F5AE5E3713');
        expect(CarDeviceId.nativeOf(''), '');
      },
    );
  });

  group('CarDeviceId.hasPrefix', () {
    test('true only for a real <brand>:<native> form', () {
      expect(CarDeviceId.hasPrefix('byd:E51DB8F5AE5E3713'), isTrue);
      expect(CarDeviceId.hasPrefix('E51DB8F5AE5E3713'), isFalse);
      expect(CarDeviceId.hasPrefix(':leading'), isFalse);
      expect(CarDeviceId.hasPrefix(''), isFalse);
    });
  });

  group('CarDeviceId.normalize', () {
    test('leaves an already-prefixed id unchanged (trimmed)', () {
      expect(
        CarDeviceId.normalize('byd:E51DB8F5AE5E3713'),
        'byd:E51DB8F5AE5E3713',
      );
      expect(
        CarDeviceId.normalize('  byd:E51DB8F5AE5E3713  '),
        'byd:E51DB8F5AE5E3713',
      );
    });
    test('prefixes a bare native id with the default brand', () {
      expect(CarDeviceId.normalize('E51DB8F5AE5E3713'), 'byd:E51DB8F5AE5E3713');
    });
    test('empty stays empty', () {
      expect(CarDeviceId.normalize(''), '');
      expect(CarDeviceId.normalize('   '), '');
    });
    test('a bare and a prefixed form of the same native id compare equal '
        'after normalize (the license-binding invariant)', () {
      expect(
        CarDeviceId.normalize('E51DB8F5AE5E3713'),
        CarDeviceId.normalize('byd:E51DB8F5AE5E3713'),
      );
    });
  });
}
