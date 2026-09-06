/// Typed feature record — brand-agnostic.
///
/// One per entry in a brand's catalog (`.secrets/<brand>/catalog.tsv`
/// + `catalog_meta.yaml` overrides). Constructed once at SDK boot
/// and held for the app's lifetime — catalogs can be 10-20k entries,
/// so the load step does the parse work once and the SDK serves
/// instances thereafter.
library;

/// Value type for a feature. Defaults to [intT] when not specified
/// in the brand's `catalog_meta.yaml`.
enum CarValueKind { intT, doubleT, bytesT, intArrayT }

/// Immutable feature metadata. The corresponding live VALUE comes
/// separately via the SDK's reactive client.
///
/// Same shape across brands — a `BatteryPercentage` on a BYD vs a
/// Geely has the same record type even though the underlying
/// `name` / `id` will differ between brand catalogs.
class CarFeature {
  const CarFeature({
    required this.name,
    required this.id,
    required this.namespace,
    required this.description,
    this.unit,
    this.semantics,
    this.dtHint,
    this.valueKind = CarValueKind.intT,
    this.readOnly = true,
    this.category,
  });

  /// Full catalog name as the brand framework reports it.
  /// BYD example: `Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT`.
  /// Geely example (future): would differ but follow the same
  /// `<Namespace>.<NAME>` convention.
  final String name;

  /// Framework integer the host's read API accepts.
  final int id;

  /// Namespace prefix (everything before the first dot, or empty).
  /// `Door`, `Bodywork`, `Ac`, `Setting`, …
  final String namespace;

  /// Human-readable description. From the brand's `catalog_meta.yaml`
  /// override if present; otherwise a humanised version of [name].
  final String description;

  /// Display unit (`%`, `°C`, `kPa`, `km`) — null for enum / boolean
  /// signals where a unit doesn't apply.
  final String? unit;

  /// Free-form note about value semantics — `"1=on, 2=off"`,
  /// `"kPa × 10"`, `"-10011 = sentinel for not-bound"`. Null for
  /// trivial integer signals.
  final String? semantics;

  /// Device-type the framework dispatches under. Lets the SDK
  /// skip runtime probing when set. Brand-specific meaning.
  final int? dtHint;

  /// Read return type — most are int.
  final CarValueKind valueKind;

  /// `false` when the feature accepts writes (brand-specific
  /// dispatch API). The SDK's invoke() refuses to write to
  /// read-only entries.
  final bool readOnly;

  /// UI grouping hint — `"doors"`, `"climate"`, `"battery"`.
  /// Defaults to lowercase [namespace] when not set in
  /// catalog_meta.yaml.
  final String? category;
}
