import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preferred_network_mode.dart' show networkInfoMethodChannel;

/// Stream of the device's current connectivity state. The plugin emits
/// a `List<ConnectivityResult>` because a device can be on multiple
/// transports at once (wifi + ethernet, wifi + mobile during handover).
/// The TopStatusBar collapses this list down to a single icon via
/// [primaryConnectivityProvider] below — the list itself is exposed
/// here for any consumer that wants the raw set (Bluetooth/USB
/// indicators, dev-bench probes, etc.).
///
/// Riverpod's `StreamProvider` handles the subscribe/cancel lifecycle
/// — when no UI is watching, the underlying platform listener is
/// torn down. The Connectivity().checkConnectivity() seed is yielded
/// up front so the indicator paints with the correct icon on the
/// first frame instead of flashing "offline" while the platform
/// channel boots.
final connectivityProvider = StreamProvider<List<ConnectivityResult>>((
  ref,
) async* {
  final connectivity = Connectivity();
  // Seed: emit the current value before the stream's first event so
  // the indicator doesn't render as "offline" for ~100 ms on cold
  // launch.
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

/// Collapsed single-result view of [connectivityProvider]. Picks the
/// "best" transport from the list using a priority order matching
/// what users intuitively read as "the connection":
///
///   ethernet > wifi > mobile > vpn > bluetooth > other > none
///
/// Why ethernet first: a docked head unit on a wired interface (rare
/// but exists in some BYD configurations) is the highest-quality
/// link, and the indicator should reflect that before falling back
/// to wifi. VPN ranks below mobile because most users see "VPN" and
/// want to know what's underneath; a future patch can stack the icons
/// if that distinction becomes visible-worthy.
final primaryConnectivityProvider = Provider<ConnectivityResult>((ref) {
  const priority = <ConnectivityResult>[
    ConnectivityResult.ethernet,
    ConnectivityResult.wifi,
    ConnectivityResult.mobile,
    ConnectivityResult.vpn,
    ConnectivityResult.bluetooth,
    ConnectivityResult.other,
  ];
  final asyncResults = ref.watch(connectivityProvider);
  final results = asyncResults.value ?? const <ConnectivityResult>[];
  if (results.isEmpty) return ConnectivityResult.none;
  for (final p in priority) {
    if (results.contains(p)) return p;
  }
  return ConnectivityResult.none;
});

/// Cellular generation, one of `2g`/`3g`/`4g`/`5g`, or null when:
///   * the active transport isn't cellular,
///   * the platform is iOS / web / desktop (channel never registered),
///   * the SIM is absent / radio is off,
///   * READ_PHONE_STATE was denied (sub-API-29 only).
///
/// Polls every 30 s while the indicator is visible. Fast enough that
/// a hand-off (LTE → 5G) reaches the indicator within half a minute,
/// slow enough that the radio's report-back doesn't burn cycles.
final cellularGenerationProvider = StreamProvider<String?>((ref) async* {
  Future<String?> probe() async {
    try {
      return await networkInfoMethodChannel.invokeMethod<String>(
        'getCellularGeneration',
      );
    } on MissingPluginException {
      return null; // iOS / web / desktop
    } on PlatformException {
      return null; // permission denied / SIM absent / unexpected
    }
  }

  // Gate the inner 30s loop on mobile transport. When the device is
  // on wifi/ethernet the radio's cellular generation is irrelevant to
  // the indicator, so polling burns cycles for no UI signal. We watch
  // [primaryConnectivityProvider] — a transport flip out of mobile
  // suspends polling until the next mobile event, and we always probe
  // on transport change for an immediate read.
  yield await probe();
  while (true) {
    final primary = ref.read(primaryConnectivityProvider);
    if (primary == ConnectivityResult.mobile) {
      await Future<void>.delayed(const Duration(seconds: 30));
      yield await probe();
    } else {
      // Park until the transport flips. The connectivity primary
      // provider is rebuilt on every connectivityProvider event, so
      // awaiting its next change is a cheap broadcast wait.
      final completer = Completer<void>();
      final sub = ref.listen<ConnectivityResult>(primaryConnectivityProvider, (
        _,
        next,
      ) {
        if (next == ConnectivityResult.mobile && !completer.isCompleted) {
          completer.complete();
        }
      });
      try {
        await completer.future;
      } finally {
        sub.close();
      }
      yield await probe();
    }
  }
});
