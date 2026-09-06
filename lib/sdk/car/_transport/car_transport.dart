import 'dart:async';

/// Transport-agnostic surface for reaching the car. Every dispatcher, router,
/// and feature layer inside `dash/lib/features/_car_domain/**` must depend on this
/// interface — never on a concrete bridge — so a new transport (local ADB,
/// cloud HTTPS, BLE, MQTT) is a new implementation, not a fork of the
/// existing router.
///
/// Current implementations:
///   - [CarBridge] — local ADB loopback + BYDAutoManager reflection + AC
///     binder Parcels. Lives in `car_bridge.dart` and wraps the method
///     channel `ilink/car`.
///   - Future `BydCloudTransport` (Phase 6) — slots in alongside the local
///     one; `CompositeToolRouter` already fans out per-command to whichever
///     transport claims it.
///
/// Keep this interface narrow. Anything specific to one transport (ADB
/// daemon internals, a cloud endpoint URL, a binder service name) belongs
/// in the implementation, not here.
abstract class CarTransport {
  /// Registered action id → single dispatch. FAST/UNIT split is an internal
  /// concern of the implementation.
  Future<Map<String, dynamic>> runAction(
    String id, [
    Map<String, dynamic> args = const {},
  ]);

  /// Direct unit invocation, skipping the action id alias map. Only used
  /// by the debug surface and internal tests.
  Future<Map<String, dynamic>> runUnit(String unit, List<String> args);

  /// Ids the implementation can currently dispatch. Empty under mock mode
  /// or when the transport is unhealthy; contract checks skip automatically
  /// on empty.
  Future<List<String>> knownActions();

  Future<List<String>> knownUnits();

  /// Auto-discovered live feature snapshot — every catalog entry the
  /// car currently exposes through the BYD framework, name → integer.
  /// Empty until the AutoCarRegistry build finishes (~5 sec after app
  /// start). The map is keyed by FULL catalog names
  /// (`Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`,
  /// `Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE`, …) — UI consumers
  /// group by prefix client-side, no per-trim wiring.
  Future<Map<String, int>> allFeaturesAuto();

  /// The FULL framework catalog — every feature BYD's framework
  /// knows about. Universal across BYD trims that ship the same
  /// DiLink version. Pull once at app start and cache; stable for
  /// the app's lifetime.
  ///
  /// Use with [allFeaturesAuto] to determine which features are
  /// currently bound on THIS car: a name in [allKnownFeatures] but
  /// absent from [allFeaturesAuto] = framework knows the feature
  /// but the trim doesn't expose it.
  Future<Map<String, int>> allKnownFeatures();

  /// `legacy-label → full-catalog-name` map for the textproto
  /// status_keys block. Used by [CarGateAdapter] to bridge existing
  /// label-keyed widgets onto the universal catalog-name-keyed
  /// store. Pulled once at SDK construct; stable thereafter.
  Future<Map<String, String>> labelToCatalog();

  /// Fresh per-feature read by catalog name. Used by the SDK when
  /// the registry's snapshot doesn't have a cached value for a name
  /// (typical for state-change-only signals like doors that don't
  /// push at boot). Always hits the daemon's autoMgr.getInt for
  /// freshest data; null when the name doesn't resolve OR all
  /// device-types return sentinels.
  Future<int?> getValueByName(String name);

  /// Bulk variant — fetch many features in one daemon round-trip via
  /// the Phase 3 grouped getIntArray path. SDK coalesces N pending
  /// fallback lookups (e.g. 16 widgets each watching ~5 features at
  /// boot) into a single call.
  Future<Map<String, int>> getValuesByName(List<String> names);

  /// Registry-free push subscription. Asks the host to register an
  /// in-app push listener for each name in [names]; matched value
  /// changes flow through the existing `ilink/car/registry` event
  /// channel. Returns the subset of [names] that successfully
  /// subscribed (those resolved to a live `(dt, key)` pair).
  ///
  /// Call once at boot for the warm set + on first watch() of any
  /// additional name. Idempotent — second call with a name that's
  /// already subscribed is a no-op.
  Future<List<String>> subscribePushByNames(List<String> names);

  /// Diagnostic snapshot of the AutoCarRegistry engine — total live
  /// entries, push frames received, etc. Empty when the registry
  /// hasn't built yet or the host is in mock mode.
  Future<Map<String, dynamic>> registryStats();

  /// Health probe; shape is transport-specific. Consumers should treat the
  /// map as opaque other than boolean `ok`-style keys.
  Future<Map<String, dynamic>> daemonStatus();

  /// Identity probe for feature-gating on a compatible car. Best-effort —
  /// keys may be missing on a transport where reflection failed.
  Future<Map<String, dynamic>> carIdentity();

  /// Local-only identity probe — same shape as [carIdentity] but skips
  /// any daemon round-trip. Used by device-fingerprint at boot when the
  /// daemon may not be ready yet.
  Future<Map<String, dynamic>> carIdentityLocalOnly();

  /// Raw binder / AIDL transaction on the air-conditioning service. Kept on
  /// the interface because several registry commands route through it
  /// directly (climate.comfort_mode, climate.rear_lock, fragrance status).
  /// Implementations that can't reach the binder should return a failure
  /// map (`{error: ..., code: ...}`), not throw.
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  });

  /// One-shot read of a BYD ContentProvider family snapshot. Returns
  /// null when the family is unknown or the provider returned no rows.
  Future<Map<String, dynamic>?> readContentProvider(String family);
}
