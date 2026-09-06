/// THE single source of truth for the canonical car device id.
///
/// The wire form is `<brand>:<native_id>` (per
/// `RENAME_BYD_DEVICE_ID_CONTRACT.md`) — e.g. `byd:BYDMCKLE...`. Every
/// consumer that needs to split, inspect, or normalize that prefix
/// routes through here so the convention lives in ONE file instead of
/// each service (MQTT topic builder, pairing fingerprint, license
/// binding) re-implementing `indexOf(':')` with subtly different
/// fallbacks.
///
/// Pure (no imports) so it sits at the bottom of the SDK layer and is
/// importable from kernel/, platform/, features/ and sdk/ alike.
library;

/// Static helpers over a `<brand>:<native_id>` device id. Not
/// instantiable.
abstract final class CarDeviceId {
  /// Brand assumed when an id is empty or carries no `<brand>:` prefix.
  /// The prefix is meant to be required; this keeps a legacy/unprefixed
  /// id from crashing routing (it degrades to BYD, the only brand today).
  static const defaultBrand = 'byd';

  /// THE canonical mock car device id — used on `mockCar` / web / test
  /// builds where no head unit can supply a real one. Lives here (not in
  /// each layer) so the bridge's `carIdentityLocalOnly()`, the settings
  /// seed, pairing fingerprint and MQTT-creds binding all agree on ONE
  /// value. A divergence here desyncs the MQTT creds username from
  /// settings.deviceId and the client silently refuses to connect.
  ///
  /// The native suffix is a syntactically-valid SAE 17-char VIN
  /// (uppercase alphanumeric minus I/O/Q) so it passes the backend's
  /// MQTT topic validator and `isLikelyValidChassisVin` after the
  /// `byd:` prefix is stripped.
  static const mockDeviceId = 'byd:BYDMCKLE0PARD8801';

  /// Brand segment (the part before the first `:`), lowercased by the
  /// minting side. Falls back to [defaultBrand] for an empty / colon-less
  /// / leading-colon id.
  static String brandOf(String deviceId) {
    final colon = deviceId.indexOf(':');
    return colon <= 0 ? defaultBrand : deviceId.substring(0, colon);
  }

  /// Native segment (the part after `<brand>:`). Returns the whole string
  /// for an empty / colon-less / leading-colon id (no prefix to strip).
  static String nativeOf(String deviceId) {
    final colon = deviceId.indexOf(':');
    return colon <= 0 ? deviceId : deviceId.substring(colon + 1);
  }

  /// Whether [deviceId] is in the prefixed `<brand>:<native>` form.
  static bool hasPrefix(String deviceId) => deviceId.indexOf(':') > 0;

  /// Normalize to the canonical prefixed form for equality comparisons.
  ///
  /// An already-prefixed id is returned trimmed-unchanged; a non-empty
  /// un-prefixed id is prefixed with [brand]; an empty id stays empty.
  /// Used by the license binding so a token's `did` and a freshly-read
  /// device id that differ only by the prefix still compare equal.
  static String normalize(String deviceId, {String brand = defaultBrand}) {
    final id = deviceId.trim();
    if (id.isEmpty) return '';
    return hasPrefix(id) ? id : '$brand:$id';
  }
}
