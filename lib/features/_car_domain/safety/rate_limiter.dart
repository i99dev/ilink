import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'security_bridge.dart';

/// Rate-limit bucket. One per rate class, tracking a rolling window of
/// dispatch timestamps. Not thread-safe: the router serialises calls on the
/// Dart single-threaded event loop, so contention is impossible in practice.
/// Timestamps older than [window] are evicted lazily on each check.
///
/// When the proto-driven CarTable lands (Phase 2, fully wired), each
/// FastAction/UnitAction message carries a `rate_class` enum and the
/// limiter reads the class from the table rather than inferring from the
/// command id prefix.
enum RateClass {
  actuator, // lock/unlock, trunk, windows, sunroof, hood — 10 / 10 s
  climate, // climate.*, seat.*, comfort.* — 30 / 10 s
  light, // light.*, hood stop (no-op-ish) — 30 / 10 s
  statusRead, // car.status — 5 / 1 s
  media, // radio.*, fragrance — 30 / 10 s
}

class _Bucket {
  _Bucket(this.limit, this.window);
  final int limit;
  final Duration window;
  final Queue<DateTime> _hits = Queue<DateTime>();

  bool tryAcquire(DateTime now) {
    final cutoff = now.subtract(window);
    while (_hits.isNotEmpty && _hits.first.isBefore(cutoff)) {
      _hits.removeFirst();
    }
    if (_hits.length >= limit) return false;
    _hits.addLast(now);
    return true;
  }

  int get currentDepth => _hits.length;
}

/// Callback fired once at the start and once at the end of a burst. Phase 5
/// SecureLogger hooks here when it lands — until then the default is a
/// silent no-op so tests stay hermetic. Payload kept to booleans / ints so
/// it can be serialised into a hashed log line without leaking command ids.
typedef BurstObserver = void Function(RateClass cls, bool started);

class RateLimiter {
  RateLimiter({DateTime Function()? now, BurstObserver? onBurst})
    : _now = now ?? DateTime.now,
      _onBurst = onBurst ?? _noBurst;

  static void _noBurst(RateClass cls, bool started) {}

  final DateTime Function() _now;
  final BurstObserver _onBurst;

  /// Tracks whether each class is currently in a rejection streak, so the
  /// observer gets exactly one event per burst (not one per rejected call).
  final Set<RateClass> _bursting = <RateClass>{};

  final Map<RateClass, _Bucket> _buckets = {
    RateClass.actuator: _Bucket(10, const Duration(seconds: 10)),
    RateClass.climate: _Bucket(30, const Duration(seconds: 10)),
    RateClass.light: _Bucket(30, const Duration(seconds: 10)),
    RateClass.statusRead: _Bucket(5, const Duration(seconds: 1)),
    RateClass.media: _Bucket(30, const Duration(seconds: 10)),
  };

  /// Map a registry command id to its rate class. Prefix-based today; when
  /// the CarTable proto wires up (Phase 2) this becomes a single lookup.
  static RateClass classify(String commandId) {
    if (commandId.startsWith('door.') ||
        commandId.startsWith('hood.') ||
        commandId.startsWith('window.') ||
        commandId.startsWith('sunroof.')) {
      return RateClass.actuator;
    }
    if (commandId.startsWith('climate.') ||
        commandId.startsWith('seat.') ||
        commandId.startsWith('comfort.massage') ||
        commandId.startsWith('comfort.atmos')) {
      return RateClass.climate;
    }
    if (commandId.startsWith('light.') ||
        commandId.startsWith('comfort.frag')) {
      return RateClass.light;
    }
    if (commandId == 'car.status' ||
        commandId == 'get_status' ||
        commandId == 'car_all_status') {
      return RateClass.statusRead;
    }
    if (commandId.startsWith('radio.')) return RateClass.media;
    // Unknown / raw passthroughs default to actuator — the strictest bucket
    // so an unaccounted command class can't burst without being noticed.
    return RateClass.actuator;
  }

  /// Returns true if the call is admitted; false if it should be rejected.
  /// Emits exactly one burst-start and one burst-end event per class per
  /// rejection streak. Sequence for a burst of 5 rejected calls followed by
  /// recovery: `started=true` (once), no callbacks for the 4 remaining
  /// rejects, `started=false` (once) on the first admit after recovery.
  ///
  /// [override] lets the router pass a class it already knows from the
  /// [CarCommand] registry, bypassing the prefix classifier. Falls back to
  /// prefix matching when the caller doesn't have a registry hit (raw
  /// `run_action` / `get_status` tunnel passthroughs).
  bool tryAdmit(String commandId, {RateClass? override}) {
    final cls = override ?? classify(commandId);
    final bucket = _buckets[cls]!;
    final admitted = bucket.tryAcquire(_now());
    if (admitted) {
      if (_bursting.remove(cls)) _onBurst(cls, false);
    } else {
      if (_bursting.add(cls)) _onBurst(cls, true);
    }
    return admitted;
  }

  /// Debug / telemetry snapshot.
  Map<String, int> depthSnapshot() => {
    for (final e in _buckets.entries) e.key.name: e.value.currentDepth,
  };
}

final rateLimiterProvider = Provider<RateLimiter>((ref) {
  // Tie the burst observer to the security bridge so anomaly events get
  // logged exactly once per burst. `ref.read` is intentional — the bridge
  // is stateless, no need to watch it.
  final bridge = ref.read(securityBridgeProvider);
  return RateLimiter(
    onBurst: (cls, started) {
      // Fire-and-forget; security channel handles its own failure modes.
      bridge.logBurst(rateClass: cls.name, started: started);
    },
  );
});
