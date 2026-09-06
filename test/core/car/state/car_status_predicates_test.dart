import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/state/predicates.dart';
import 'package:ilink/features/_car_domain/state/gate.dart';

/// Build a [CarGate] from the wire keys the daemon publishes — same
/// shape `CarGate.fromRaw` parses in production. Lets the tests pin
/// the predicate against the actual data path, not a synthesised
/// in-memory shape.
CarGate _gate({
  int? speedKmh,
  int? batteryPct,
  int? doorLock,
  int? doorLf,
  int? doorRf,
  int? doorLr,
  int? doorRr,
  int? trunk,
  int? acPower,
  int? evMode,
  int? hevMode,
  int? rangeEvKm,
  int? rangeFuelKm,
}) => CarGate.fromRaw(<String, dynamic>{
  'speed_kmh': ?speedKmh,
  'battery_pct': ?batteryPct,
  'door_lock': ?doorLock,
  'door_lf': ?doorLf,
  'door_rf': ?doorRf,
  'door_lr': ?doorLr,
  'door_rr': ?doorRr,
  'trunk': ?trunk,
  'ac_power': ?acPower,
  'ev_mode': ?evMode,
  'hev_mode': ?hevMode,
  'range_ev_km': ?rangeEvKm,
  'range_fuel_km': ?rangeFuelKm,
});

void main() {
  group('shouldEmitCarStatusDelta', () {
    test('first emit (prev null) always trips', () {
      expect(shouldEmitCarStatusDelta(null, _gate()), isTrue);
    });

    test('identical states do not trip', () {
      final s = _gate(speedKmh: 30, batteryPct: 80, doorLock: 2);
      expect(shouldEmitCarStatusDelta(s, s), isFalse);
    });

    group('speed', () {
      test('Δ ≤ threshold does not trip', () {
        // Threshold is > 5 km/h, so 0..5 should not trip.
        expect(
          shouldEmitCarStatusDelta(_gate(speedKmh: 50), _gate(speedKmh: 55)),
          isFalse,
        );
      });

      test('Δ > threshold trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(speedKmh: 50), _gate(speedKmh: 56)),
          isTrue,
        );
      });

      test('null → known trips (just learned speed)', () {
        expect(shouldEmitCarStatusDelta(_gate(), _gate(speedKmh: 30)), isTrue);
      });

      test('known → null trips (lost speed signal)', () {
        expect(shouldEmitCarStatusDelta(_gate(speedKmh: 30), _gate()), isTrue);
      });

      test('null → null does not trip', () {
        expect(shouldEmitCarStatusDelta(_gate(), _gate()), isFalse);
      });
    });

    group('battery', () {
      test('Δ ≥ 1% trips', () {
        expect(
          shouldEmitCarStatusDelta(
            _gate(batteryPct: 80),
            _gate(batteryPct: 79),
          ),
          isTrue,
        );
      });

      test('Δ = 0 does not trip', () {
        expect(
          shouldEmitCarStatusDelta(
            _gate(batteryPct: 80),
            _gate(batteryPct: 80),
          ),
          isFalse,
        );
      });
    });

    group('doors + lock', () {
      test('door lock flip trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(doorLock: 1), _gate(doorLock: 2)),
          isTrue,
        );
      });

      test('any individual door open/close trips', () {
        for (final field in ['doorLf', 'doorRf', 'doorLr', 'doorRr', 'trunk']) {
          final prev = _gate();
          final next = switch (field) {
            'doorLf' => _gate(doorLf: 1),
            'doorRf' => _gate(doorRf: 1),
            'doorLr' => _gate(doorLr: 1),
            'doorRr' => _gate(doorRr: 1),
            'trunk' => _gate(trunk: 1),
            _ => _gate(),
          };
          expect(
            shouldEmitCarStatusDelta(prev, next),
            isTrue,
            reason: '$field flip should trip',
          );
        }
      });
    });

    group('climate / power', () {
      test('AC flip trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(acPower: 0), _gate(acPower: 1)),
          isTrue,
        );
      });

      test('EV mode change trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(evMode: 0), _gate(evMode: 1)),
          isTrue,
        );
      });

      test('HEV mode change trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(hevMode: 0), _gate(hevMode: 1)),
          isTrue,
        );
      });
    });

    group('range', () {
      test('EV range change trips', () {
        expect(
          shouldEmitCarStatusDelta(_gate(rangeEvKm: 100), _gate(rangeEvKm: 95)),
          isTrue,
        );
      });

      test('fuel range change trips', () {
        expect(
          shouldEmitCarStatusDelta(
            _gate(rangeFuelKm: 200),
            _gate(rangeFuelKm: 180),
          ),
          isTrue,
        );
      });
    });
  });
}
