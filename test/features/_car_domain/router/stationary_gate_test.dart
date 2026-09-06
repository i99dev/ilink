import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/router/command_router.dart';

import '../../../support/fake_car_client.dart';

/// The stationary gate's speed resolver. The reported bug: a PARKED car was
/// refused "open window" with UNSAFE_WHILE_MOVING because the cache held a
/// stale "moving" speed (BYD pushes deltas — the "now stopped" frame can be
/// missed). The fix reads ground truth: trust a very-fresh cache, else force
/// a live read; fail open when no trustworthy value is available.
const _speed = 'Statistic.STATISTIC_SPEED_SIG_VDIS';

void main() {
  group('resolveStationaryGateSpeed', () {
    test('fresh cached value is trusted as-is — no live read', () async {
      final c = FakeCarClient()
        ..values[_speed] = 42
        ..freshnessByName[_speed] = const Duration(seconds: 1);

      final speed = await CarCommandRouter.resolveStationaryGateSpeed(c);

      expect(speed, 42);
      // Fast path: it must NOT pay a daemon round-trip when the cache is fresh.
      expect(c.calls.any((e) => e.method == 'refreshValue'), isFalse);
    });

    test('fresh "stopped" cache returns 0 → gate allows', () async {
      final c = FakeCarClient()
        ..values[_speed] = 0
        ..freshnessByName[_speed] = const Duration(seconds: 1);

      expect(await CarCommandRouter.resolveStationaryGateSpeed(c), 0);
    });

    test(
      'THE BUG: stale "moving" cache, live read says stopped → 0 (allow)',
      () async {
        final c = FakeCarClient()
          // What the cache wrongly held after a missed "stopped" frame…
          ..values[_speed] = 40
          ..freshnessByName[_speed] = const Duration(seconds: 30)
          // …and the ground truth when we actually ask the car now.
          ..refreshValues = {_speed: 0};

        final speed = await CarCommandRouter.resolveStationaryGateSpeed(c);

        expect(speed, 0, reason: 'a parked car must not be gated as moving');
        expect(c.calls.any((e) => e.method == 'refreshValue'), isTrue);
      },
    );

    test(
      'stale cache, live read confirms moving → blocks (cruise safety)',
      () async {
        final c = FakeCarClient()
          ..values[_speed] = 40
          ..freshnessByName[_speed] = const Duration(seconds: 30)
          ..refreshValues = {_speed: 80};

        expect(await CarCommandRouter.resolveStationaryGateSpeed(c), 80);
      },
    );

    test('never-seen + live read fails → null (fail open)', () async {
      final c = FakeCarClient()
        ..refreshThrows = true; // freshness absent → null

      expect(await CarCommandRouter.resolveStationaryGateSpeed(c), isNull);
    });

    test(
      'stale cache + live read fails → null (fail open, not stale-block)',
      () async {
        final c = FakeCarClient()
          ..values[_speed] = 40
          ..freshnessByName[_speed] = const Duration(seconds: 30)
          ..refreshThrows = true;

        // Crucially NOT 40 — a dead daemon means the actuation fails anyway, so
        // we don't resurrect the stale-blocks-a-parked-car bug.
        expect(await CarCommandRouter.resolveStationaryGateSpeed(c), isNull);
      },
    );
  });
}
