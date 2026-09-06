/// Per-(HuVendor, vehicle variant) declaration of how deeply ilink
/// integrates with this car. Distinct from `lib/features/_car_domain/profile/profile/car_profile.dart`
/// — that one models the *runtime* state of the active car (which
/// actions the daemon currently supports, what the capability bitmask
/// looks like). [CarSupportProfile] is the *static* declaration: what
/// integration tier we ship for this combo, and what known
/// gotchas to surface to the user.
///
/// The two are layered:
///
/// 1. [CarSupportRegistry] looks up the static profile by the detected
///    (HuVendor, variant) pair. This file.
/// 2. [CarProfile] (the existing runtime one) is then resolved by the
///    Kotlin host's CapabilityRegistry over the daemon's actual
///    response. Independent, but the static profile gates whether we
///    even bother attempting actuator dispatch — a `tier=stock` car
///    skips the dispatch path entirely so the runtime profile never
///    has to fail-closed inside CarCommandRouter.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'hu_vendor.dart';
import 'integration_tier.dart';
import 'known_quirk.dart';

@immutable
class CarSupportProfile {
  const CarSupportProfile({
    required this.huVendor,
    required this.variant,
    required this.tier,
    required this.displayName,
    this.quirks = const <KnownQuirk>[],
  });

  /// HU chassis the profile applies to. Some models ship across
  /// multiple chassis (e.g. Han EV on both BYD-stock and Yuanfeng
  /// aftermarket); each combination gets its own profile entry so
  /// quirks can diverge per-chassis.
  final HuVendor huVendor;

  /// Vehicle variant id — same string [ModelDetector] resolves to,
  /// e.g. `l8`, `l5`, `han_l`, `song_plus`. Empty string is the
  /// vendor-level wildcard ("any vehicle on this HU"); used for
  /// generic fallback rows.
  final String variant;

  final IntegrationTier tier;

  /// Human-readable label rendered in the About section's
  /// "Vehicle support" badge. Includes both the vehicle and the HU
  /// — e.g. "BYD Leopard 8" for `(byd, l8)`, "Han EV on Yuanfeng"
  /// for `(yuanfeng, han_l)`. Kept on the profile (not derived)
  /// because the marketing name is sometimes specific to the chassis
  /// pairing rather than the vehicle alone.
  final String displayName;

  /// Quirks the user should see ahead of attempting the affected
  /// action. Empty for fully-clean profiles.
  final List<KnownQuirk> quirks;

  /// Lookup the quirk for [actionId], or null when none applies.
  /// Linear scan — quirks lists are small (typically 0-3 entries per
  /// profile) so the index-build overhead isn't worth it.
  KnownQuirk? quirkFor(String actionId) {
    for (final q in quirks) {
      if (q.actionId == actionId) return q;
    }
    return null;
  }

  /// Sentinel returned when the registry lookup misses entirely.
  /// Keeps consumers from having to handle null at every call site —
  /// they get back a usable profile that says "we don't know this car;
  /// fail closed".
  static const CarSupportProfile unknownVehicle = CarSupportProfile(
    huVendor: HuVendor.unknown,
    variant: '',
    tier: IntegrationTier.unsupported,
    displayName: 'Unknown vehicle',
  );
}
