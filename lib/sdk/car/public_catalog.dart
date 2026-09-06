/// Brand-neutral catalog the miniapp WebView bridge exposes.
///
/// **Distinct from [CarCatalog]** at `lib/sdk/car/catalog.dart`:
///
/// - [CarCatalog] is the brand-internal one (13k+ entries, framework
///   names like `Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT` with their
///   integer feature ids). Used by the SDK's reflection / probe
///   layers, the compat reporter, gate-probe diagnostics, etc.
///
/// - [PublicCatalog] (this file) is what crosses the bridge. ~200
///   brand-neutral names (`door_lf_lock`, `wheel_speed_fl`,
///   `cabin_temp_c`) with UI metadata (category, units, range, 3d
///   flag, write-side action id). No integer ids, no framework
///   names, no brand-specific terminology.
///
/// Adding NIO / Geely later = ship a `<brand>_public_catalog.dart`
/// that returns the same shape; the bridge code is brand-agnostic.
library;

/// Read-only catalog snapshot the bridge serves to miniapps.
abstract class PublicCatalog {
  /// Total entry count.
  int get size;

  /// All entries — used by `car.list()` with no filter.
  Iterable<PublicCatalogEntry> all();

  /// Single-entry lookup. Returns `null` if the name isn't in the
  /// catalog — bridge handlers return that to the miniapp as a 404
  /// inside the wire envelope, not as a thrown error.
  PublicCatalogEntry? get(String name);

  /// Filter by [PublicCatalogEntry.category]. Empty iterable if no
  /// entries match — never `null`.
  Iterable<PublicCatalogEntry> byCategory(String category);

  /// Filter to entries marked [PublicCatalogEntry.threeD] — the
  /// 3D-miniapp-friendly subset (animation drivers + render hints).
  Iterable<PublicCatalogEntry> threeD();

  /// Distinct categories present in the catalog, sorted.
  List<String> categories();
}

/// One catalog entry — fully describes a single signal that crosses
/// the bridge. Designed for round-trip-safe JSON serialisation; the
/// bridge marshals these into `car.list()` responses verbatim.
class PublicCatalogEntry {
  const PublicCatalogEntry({
    required this.name,
    required this.category,
    required this.description,
    this.units,
    this.range,
    this.writeable = false,
    this.writeActionId,
    this.wireActionId,
    this.binderOnly = false,
    this.threeD = false,
  });

  /// Brand-neutral lower-snake-case identifier. THIS is what the
  /// miniapp passes to `car.read()` / `car.subscribe()`.
  ///
  /// **Stable contract.** Renaming is a breaking change; we treat
  /// it as a new name + soft-alias period if ever needed.
  final String name;

  /// Coarse UI grouping. Stable values: `doors`, `lights`,
  /// `climate`, `propulsion`, `dynamics`, `cabin`, `system`,
  /// `media`, `safety`, `connectivity`. New categories are
  /// additive — bridge consumers should treat unknown values as
  /// "uncategorised".
  final String category;

  /// Human-readable description. Shown in the docs catalog table;
  /// the SDK does not surface this at runtime, but bridge consumers
  /// can echo it for tooling / inspectors.
  final String description;

  /// Display unit (`celsius`, `percent`, `km/h`, `kpa`, `seconds`)
  /// or `null` for enums / booleans where a unit doesn't apply.
  final String? units;

  /// Expected integer value range — set on bounded signals
  /// (temperature, percentage, fan speed). `null` for free-form or
  /// enum values; the miniapp should treat `null` as "consult the
  /// description / semantics".
  final IntRange? range;

  /// `true` when there is a write-side action that mutates this
  /// signal. The miniapp does NOT call `car.read` to write — it
  /// calls `car.command(actionId)` with the action id below.
  final bool writeable;

  /// SDK action id for writing this signal — e.g. `door.lock.fl`,
  /// `climate.temp.set`. `null` when [writeable] is `false`. The
  /// miniapp passes this string to `car.command()`; the host's
  /// `CarCommandRouter` does the dispatch + gating.
  ///
  /// **Until Phase 2 of the command-methodology rename ships**, the
  /// daemon's UnitDispatcher does NOT recognise this string directly
  /// — the host translates it to [wireActionId] before dispatch.
  /// Mini-apps don't need to know the difference; they pass
  /// `writeActionId` and the host bridges.
  final String? writeActionId;

  /// Daemon-recognised wire action id (from
  /// `.secrets/car_table/car_table.textproto`). Exposed so privileged
  /// surfaces (admin / dev tools / Phase 4 registry codegen) can
  /// resolve the catalog → daemon mapping without re-implementing
  /// the bridge.
  ///
  /// `null` when one of:
  ///   * The signal is read-only.
  ///   * The signal writes through a non-FAST path (binder, etc.).
  ///   * Phase 3 hasn't backfilled this entry yet.
  ///
  /// Mini-apps should NOT use this field — pass [writeActionId] to
  /// `car.command()`; the host owns wire-id resolution.
  final String? wireActionId;

  /// `true` when [writeable] is true but writes route through a
  /// non-FAST transport (Android binder, `acTransact`, or a
  /// `unit_actions` interpreter inside the daemon) rather than a
  /// `fast_actions { action_id }` row in the textproto. Bridge
  /// consumers do not need to distinguish — the host routes correctly
  /// from [writeActionId] — but the catalog ↔ wire parity test uses
  /// this flag to exempt the entry from the FAST-backfill TODO list.
  final bool binderOnly;

  /// `true` when this signal drives a 3D-miniapp animation or
  /// renderer state. The 3D-friendly subset is the set returned by
  /// [PublicCatalog.threeD]. UI clients can filter on this for a
  /// "show 3D animations only" toggle.
  final bool threeD;

  /// Wire shape used by `car.list()` responses. Stable JSON keys
  /// — order matches the bridge contract version. [wireActionId] is
  /// intentionally NOT serialised — it's a host-internal detail
  /// that mini-apps don't need (they pass [writeActionId] and the
  /// host bridges to the wire id).
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'category': category,
    'description': description,
    if (units != null) 'units': units,
    if (range != null) 'range': range!.toJson(),
    'writeable': writeable,
    if (writeActionId != null) 'writeActionId': writeActionId,
    'threeD': threeD,
  };
}

/// Inclusive bounded integer range. Floats round to int — every
/// signal that crosses the SDK boundary is an integer (per
/// `CarValueKind.intT` being the default), so `min` and `max`
/// describe the int wire value (which may be `× 10` for temps —
/// see [PublicCatalogEntry.description] for the divisor).
class IntRange {
  const IntRange(this.min, this.max);
  final int min;
  final int max;

  Map<String, Object?> toJson() => <String, Object?>{'min': min, 'max': max};
}
