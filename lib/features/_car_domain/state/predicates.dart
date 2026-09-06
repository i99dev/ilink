/// Single source of truth for "did anything user-visible change in
/// the car gate?".
///
/// Used by:
///   * `lib/app/mqtt/status_publisher.dart` — gates MQTT uplink so a
///     parked car costs ~2 msg/min instead of 6.
///   * `lib/features/mini_apps/state/car_status_fanout.dart` — gates
///     the local WebView push so mini-apps see a delta only when
///     something actually changed.
///
/// Keeping the predicate in ONE file means a threshold change (e.g.
/// bumping the speed delta from 5 km/h to 10) lands in one diff and
/// stays in lockstep across both consumers.
///
/// Pure / no Flutter dependencies → cheap unit tests.
library;

import 'gate.dart';

/// Speed delta threshold (km/h). Bigger values reduce push volume on
/// stop-and-go traffic; smaller values give finer-grained UI updates.
/// 5 was the original tradeoff agreed for MQTT observability.
const int kSpeedDeltaKmh = 5;

/// Battery percentage delta. ≥1% so a slow drain on a parked car
/// (≈0.5%/h) doesn't keep emitting.
const int kBatteryDeltaPct = 1;

/// Predicate: should `next` be considered a meaningful update relative
/// to `prev`? `null` prev (first call) ALWAYS emits; otherwise we
/// trip on any field consumers care about flipping.
///
/// **Does NOT include the keep-alive (30s) heartbeat** — that is
/// MQTT-specific (lets the backend distinguish "car offline" from
/// "no real change") and is owned by `StatusPublisher`. Mini-apps
/// don't need a heartbeat at the JS level; the SDK exposes
/// `connection state` through a separate channel.
bool shouldEmitCarStatusDelta(CarGate? prev, CarGate next) {
  if (prev == null) return true;

  if (_speedDeltaTripped(prev.dynamics.speedKmh, next.dynamics.speedKmh)) {
    return true;
  }
  if (_batteryDeltaTripped(
    prev.powertrain.batteryPct,
    next.powertrain.batteryPct,
  )) {
    return true;
  }
  if (prev.closures.doorLock != next.closures.doorLock) return true;
  if (_anyDoorChanged(prev.closures, next.closures)) return true;
  if (prev.climate.acPower != next.climate.acPower) return true;
  if (prev.powertrain.evMode != next.powertrain.evMode ||
      prev.powertrain.hevMode != next.powertrain.hevMode) {
    return true;
  }
  if (prev.powertrain.rangeEvKm != next.powertrain.rangeEvKm ||
      prev.powertrain.rangeFuelKm != next.powertrain.rangeFuelKm) {
    return true;
  }
  return false;
}

bool _speedDeltaTripped(int? a, int? b) {
  if (a == null && b == null) return false;
  if (a == null || b == null) return true; // just learned / lost speed
  return (a - b).abs() > kSpeedDeltaKmh;
}

bool _batteryDeltaTripped(int? a, int? b) {
  if (a == null && b == null) return false;
  if (a == null || b == null) return true;
  return (a - b).abs() >= kBatteryDeltaPct;
}

bool _anyDoorChanged(ClosuresGate a, ClosuresGate b) {
  return a.doorLf != b.doorLf ||
      a.doorRf != b.doorRf ||
      a.doorLr != b.doorLr ||
      a.doorRr != b.doorRr ||
      a.trunk != b.trunk;
}
