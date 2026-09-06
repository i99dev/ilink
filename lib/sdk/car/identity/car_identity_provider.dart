/// Single Riverpod source of truth for "what can the active car
/// actually do". Wraps the host-side `CarProfilePlatformPlugin`
/// behind a cached future so the catalog filter, the
/// `display.list` emitter, [CarCommandRouter], and any future
/// cap-aware UI all read the same answer without each one
/// re-crossing the platform channel.
///
/// Refresh semantics: cached for the process lifetime by default.
/// The underlying registry is essentially static (per-trim seed +
/// backend overlay) and only mutates when `CapabilityProber.sync()`
/// lands a new overlay. Call
/// `ref.invalidate(carProfileProvider)` after a successful probe
/// sync to pick up the new bits.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'car_profile.dart';
import '../_transport/car_profile_native_bridge.dart';

/// Direct access to the platform bridge. Tests override this to
/// feed a fake [CarProfileNativeBridge]; production wires the real
/// [PlatformCarProfileNativeBridge].
final carProfileBridgeProvider = Provider<CarProfileNativeBridge>(
  (_) => PlatformCarProfileNativeBridge(),
);

/// Active car's [CarProfile]. Cached for the lifetime of the
/// provider; rebuild with `ref.invalidate(carProfileProvider)` after
/// a probe sync writes a new backend overlay.
///
/// Returns the empty fallback [CarProfile.empty] on platform-channel
/// error so the catalog merge degrades gracefully — the worst case
/// is every cap-required app showing a `caps_missing` reason rather
/// than the catalog rendering nothing.
final carProfileProvider = FutureProvider<CarProfile>((ref) async {
  final bridge = ref.watch(carProfileBridgeProvider);
  try {
    return await bridge.snapshot();
  } catch (_) {
    // Defensive — never fail the whole catalog merge on a probe
    // failure. Empty CarProfile == "we don't know what this car
    // can do", which is the conservative default.
    return CarProfile.empty;
  }
});
