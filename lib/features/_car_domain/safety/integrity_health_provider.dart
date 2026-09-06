import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'security_bridge.dart';

/// Periodically polls the Kotlin [IntegrityMonitor] through [SecurityBridge]
/// and surfaces its health to UI consumers.
///
/// Poll cadence is deliberately coarse (5 s): the monitor itself only
/// re-evaluates every 60 s, and a flipped-unhealthy state persists until
/// the daemon restarts. Anything finer just burns channel round-trips
/// without visible benefit.
///
/// Fails *open* on channel errors (bridge already returns true when the
/// security plugin is absent) so tests, mock builds, and devices without
/// the native monitor don't spuriously show a tamper banner.
final integrityHealthyProvider = StreamProvider<bool>((ref) async* {
  final bridge = ref.watch(securityBridgeProvider);
  // Emit an immediate initial value so the banner doesn't flash in
  // during the first poll interval on cold start.
  yield await bridge.integrityHealthy();
  final timer = Stream.periodic(const Duration(seconds: 5));
  await for (final _ in timer) {
    yield await bridge.integrityHealthy();
  }
});
