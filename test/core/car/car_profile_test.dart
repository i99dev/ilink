import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/car/identity/car_profile.dart';
import 'package:ilink/sdk/car/identity/profile_key.dart';

void main() {
  group('ProfileKey', () {
    test('roundtrips through JSON', () {
      const key = ProfileKey(
        firmwareVersion: 'di5.0',
        modelName: 'l5',
        subTrim: 'flagship',
        fingerprint: 'BYD/...',
      );
      final json = key.toJson();
      expect(json['dilinkFamily'], 'di5.0');
      expect(json['subTrim'], 'flagship');
      expect(ProfileKey.fromJson(json), key);
    });

    test('unknown sentinel parses identically to fromJson empty', () {
      final json = ProfileKey.unknown.toJson();
      expect(ProfileKey.fromJson(json), ProfileKey.unknown);
    });

    test('equality is structural', () {
      const a = ProfileKey(
        firmwareVersion: 'di5.1',
        modelName: 'l8',
        subTrim: 'base',
        fingerprint: 'fp',
      );
      const b = ProfileKey(
        firmwareVersion: 'di5.1',
        modelName: 'l8',
        subTrim: 'base',
        fingerprint: 'fp',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('fromJson tolerates missing optional slots', () {
      final key = ProfileKey.fromJson(const {'dilinkFamily': 'di5.1'});
      expect(key.firmwareVersion, 'di5.1');
      expect(key.modelName, '');
      expect(key.subTrim, '');
      expect(key.fingerprint, '');
    });
  });

  group('CarActionSupport.fromWire', () {
    test('matches host enum names', () {
      expect(
        CarActionSupport.fromWire('SUPPORTED'),
        CarActionSupport.supported,
      );
      expect(
        CarActionSupport.fromWire('UNSUPPORTED'),
        CarActionSupport.unsupported,
      );
      expect(
        CarActionSupport.fromWire('UNKNOWN_ASSUME_SUPPORTED'),
        CarActionSupport.unknownAssumeSupported,
      );
    });

    test('unknown wire string falls back to UNKNOWN_ASSUME_SUPPORTED', () {
      // Defensive — host could ship a future enum value we don't
      // recognise; safest default is "let the daemon decide".
      expect(
        CarActionSupport.fromWire('FUTURE_VALUE'),
        CarActionSupport.unknownAssumeSupported,
      );
      expect(
        CarActionSupport.fromWire(null),
        CarActionSupport.unknownAssumeSupported,
      );
    });
  });

  group('CarProfile.fromMap', () {
    final wire = {
      'key': {
        'dilinkFamily': 'di5.0',
        'variantId': 'l5',
        'subTrim': 'navigator',
        'fingerprint': 'BYD/l5/...',
      },
      'isFallback': false,
      'fallbackReason': null,
      'friendlyName': 'Leopard 5 Navigator',
      'capabilityBits': 0x3,
      'capabilities': ['display.read', 'pkg.read'],
      'capabilitiesSource': 'backend',
      'actionSupport': {
        'set_seat_massage': 'UNSUPPORTED',
        'unlock_door': 'UNKNOWN_ASSUME_SUPPORTED',
      },
    };

    test('decodes the canonical wire shape', () {
      final p = CarProfile.fromMap(wire);
      expect(p.key.subTrim, 'navigator');
      expect(p.capabilityBits, 0x3);
      expect(p.capabilities, ['display.read', 'pkg.read']);
      expect(p.isFallback, isFalse);
      expect(p.friendlyName, 'Leopard 5 Navigator');
    });

    test('supportFor returns the seeded entry', () {
      final p = CarProfile.fromMap(wire);
      expect(p.supportFor('set_seat_massage'), CarActionSupport.unsupported);
    });

    test(
      'supportFor defaults to unknownAssumeSupported for unseeded actions',
      () {
        // The fast-deny short-circuit MUST default to "try" for actions
        // outside the seed — otherwise every new action would be
        // silently denied until someone added a seed entry.
        final p = CarProfile.fromMap(wire);
        expect(
          p.supportFor('action_not_in_map'),
          CarActionSupport.unknownAssumeSupported,
        );
      },
    );

    test('empty fallback has zero caps and no support entries', () {
      // Empty == "we don't know what this car can do". Hot path
      // contract: catalog filter dims everything that needs caps,
      // CarCommandRouter falls through to the daemon authority.
      expect(CarProfile.empty.capabilityBits, 0);
      expect(CarProfile.empty.capabilities, isEmpty);
      expect(CarProfile.empty.actionSupport, isEmpty);
      expect(CarProfile.empty.isFallback, isTrue);
    });
  });
}
