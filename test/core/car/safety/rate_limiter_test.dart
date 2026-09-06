import 'package:ilink/features/_car_domain/safety/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RateLimiter.classify', () {
    test('actuator prefixes route to actuator class', () {
      expect(RateLimiter.classify('door.lock'), RateClass.actuator);
      expect(RateLimiter.classify('door.unlock'), RateClass.actuator);
      expect(RateLimiter.classify('hood.open'), RateClass.actuator);
      expect(RateLimiter.classify('window.fl.open'), RateClass.actuator);
      expect(RateLimiter.classify('sunroof.open'), RateClass.actuator);
    });

    test('climate + seat + massage + atmos land in climate class', () {
      expect(RateLimiter.classify('climate.power'), RateClass.climate);
      expect(RateLimiter.classify('climate.compressor'), RateClass.climate);
      expect(RateLimiter.classify('seat.heat.drv'), RateClass.climate);
      expect(RateLimiter.classify('seat.vent.drv'), RateClass.climate);
      expect(RateLimiter.classify('comfort.massage'), RateClass.climate);
      expect(RateLimiter.classify('comfort.atmos'), RateClass.climate);
    });

    test('light + fragrance land in light class', () {
      expect(RateLimiter.classify('light.head'), RateClass.light);
      expect(RateLimiter.classify('light.turn_left'), RateClass.light);
      expect(RateLimiter.classify('comfort.frag.on'), RateClass.light);
    });

    test('status reads isolated', () {
      expect(RateLimiter.classify('car.status'), RateClass.statusRead);
      expect(RateLimiter.classify('get_status'), RateClass.statusRead);
      expect(RateLimiter.classify('car_all_status'), RateClass.statusRead);
    });

    test('radio → media', () {
      expect(RateLimiter.classify('radio.play_by_name'), RateClass.media);
      expect(RateLimiter.classify('radio.pause'), RateClass.media);
    });

    test('unknown command falls through to strictest bucket', () {
      expect(RateLimiter.classify('bogus.unknown'), RateClass.actuator);
    });
  });

  group('RateLimiter bucket behaviour', () {
    test('admits up to limit then rejects within the window', () {
      final now = DateTime(2026, 4, 20, 12, 0, 0);
      final limiter = RateLimiter(now: () => now);
      // actuator bucket: 10 per 10 s
      for (var i = 0; i < 10; i++) {
        expect(limiter.tryAdmit('door.lock'), isTrue, reason: 'hit #$i');
      }
      expect(
        limiter.tryAdmit('door.lock'),
        isFalse,
        reason: '11th hit should be rejected',
      );
    });

    test('window rolls forward: old hits evicted after window elapses', () {
      var now = DateTime(2026, 4, 20, 12, 0, 0);
      final limiter = RateLimiter(now: () => now);
      for (var i = 0; i < 10; i++) {
        expect(limiter.tryAdmit('door.lock'), isTrue);
      }
      expect(limiter.tryAdmit('door.lock'), isFalse);
      // Jump past the 10 s window — all prior hits evicted.
      now = now.add(const Duration(seconds: 11));
      expect(limiter.tryAdmit('door.lock'), isTrue);
    });

    test('buckets are independent per class', () {
      final now = DateTime(2026, 4, 20, 12, 0, 0);
      final limiter = RateLimiter(now: () => now);
      // Exhaust actuator bucket.
      for (var i = 0; i < 10; i++) {
        limiter.tryAdmit('door.lock');
      }
      expect(limiter.tryAdmit('door.lock'), isFalse);
      // Climate bucket still has headroom.
      expect(limiter.tryAdmit('climate.power'), isTrue);
      // Status-read bucket: 5 / 1 s
      for (var i = 0; i < 5; i++) {
        expect(limiter.tryAdmit('car.status'), isTrue);
      }
      expect(limiter.tryAdmit('car.status'), isFalse);
    });

    test('status-read bucket: 5 per second', () {
      var now = DateTime(2026, 4, 20, 12, 0, 0);
      final limiter = RateLimiter(now: () => now);
      for (var i = 0; i < 5; i++) {
        expect(limiter.tryAdmit('car.status'), isTrue);
      }
      expect(limiter.tryAdmit('car.status'), isFalse);
      now = now.add(const Duration(milliseconds: 1100));
      expect(limiter.tryAdmit('car.status'), isTrue);
    });
  });

  group('RateLimiter burst observer', () {
    test('fires started once then ended once across a burst', () {
      var now = DateTime(2026, 4, 20, 12, 0, 0);
      final events = <({RateClass cls, bool started})>[];
      final limiter = RateLimiter(
        now: () => now,
        onBurst: (cls, started) => events.add((cls: cls, started: started)),
      );
      // Exhaust the actuator bucket.
      for (var i = 0; i < 10; i++) {
        limiter.tryAdmit('door.lock');
      }
      // First reject → burst-started.
      limiter.tryAdmit('door.lock');
      // Further rejects → no additional events.
      limiter.tryAdmit('door.lock');
      limiter.tryAdmit('door.lock');
      expect(events, hasLength(1));
      expect(events.first.started, isTrue);
      expect(events.first.cls, RateClass.actuator);
      // Jump the window; next admit → burst-ended.
      now = now.add(const Duration(seconds: 11));
      limiter.tryAdmit('door.lock');
      expect(events, hasLength(2));
      expect(events.last.started, isFalse);
      expect(events.last.cls, RateClass.actuator);
    });

    test(
      'bursts are per-class — exhausting one class does not flip another',
      () {
        final now = DateTime(2026, 4, 20, 12, 0, 0);
        final events = <RateClass>[];
        final limiter = RateLimiter(
          now: () => now,
          onBurst: (cls, started) {
            if (started) events.add(cls);
          },
        );
        for (var i = 0; i < 10; i++) {
          limiter.tryAdmit('door.lock');
        }
        limiter.tryAdmit('door.lock');
        expect(events, [RateClass.actuator]);
        // Climate still has headroom — admit, no burst for climate.
        limiter.tryAdmit('climate.power');
        expect(events, [RateClass.actuator]);
      },
    );
  });
}
