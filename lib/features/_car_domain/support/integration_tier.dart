/// Depth of integration ilink has with the active vehicle.
///
/// Distinct from the privacy `Tier1` / `Tier2` interfaces in
/// `lib/features/_car_domain/tiers.dart` (those classify whether a *field* is
/// privacy-sensitive). This enum classifies the *vehicle-and-HU
/// combination* itself: how much of the actuator surface ilink can
/// reach, and how much the user can rely on.
///
/// Resolution: a [CarSupportProfile] looked up from the registry
/// declares the tier for a given (HuVendor, vehicle variant) pair.
/// Unknown combinations default to [unsupported] — fail closed; no
/// dispatch attempts are made beyond what the daemon's stock-API
/// surface allows.
enum IntegrationTier {
  /// Full reverse-engineered actuator control + cluster surface.
  /// Doors, windows, climate, seats, fragrance, lights — all wired.
  /// Today: Leopard 5 family + Leopard 8 on DiLink 5.1.
  full('full', 'Full integration'),

  /// Read-only telemetry + voice + MQTT uplink + launcher mode.
  /// No actuator dispatch attempted (stock Android APIs only). Safe
  /// fallback for any DiLink HU we recognise but haven't reverse-
  /// engineered the control plane for yet.
  stock('stock', 'Stock APIs only'),

  /// We don't recognise this combination. The app still loads but
  /// car-control surfaces stay dimmed to "unsupported on this car".
  /// Eventually a registry entry promotes the combo to [stock] or
  /// [full].
  unsupported('unsupported', 'Unsupported');

  const IntegrationTier(this.wireValue, this.displayLabel);

  /// Stable string for serialization (Sentry tags, MQTT, telemetry).
  /// Kept lowercase + underscore-free so backend dashboards can group
  /// without normalisation.
  final String wireValue;

  /// Human-readable label for in-app surfaces (About section, the
  /// Diagnostics card). Translated copies live in the .arb files
  /// under the matching key prefix; this English string is the
  /// source-of-truth fallback.
  final String displayLabel;

  /// Reverse lookup for parsing wire values (Sentry replay, persisted
  /// state). Unknown / null falls through to [unsupported] —
  /// fail-closed posture matches the registry default.
  static IntegrationTier fromWire(String? raw) {
    for (final t in IntegrationTier.values) {
      if (t.wireValue == raw) return t;
    }
    return IntegrationTier.unsupported;
  }

  /// True when the tier permits any actuator dispatch. Both gates
  /// (CarCommandRouter + the mini-app catalog filter) consult this
  /// to decide between "try and let the daemon authority decide" and
  /// "fail closed before round-tripping".
  bool get allowsActuatorDispatch => this == IntegrationTier.full;

  /// True when the tier permits read-only telemetry surfaces (battery
  /// percent, GPS, etc.). [full] and [stock] both qualify; only
  /// [unsupported] dims read surfaces.
  bool get allowsReadTelemetry => this != IntegrationTier.unsupported;
}
