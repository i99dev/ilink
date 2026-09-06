import '../../features/mini_apps/runtime/display_snapshot.dart';

/// Single-source-of-truth for the friendly display label that
/// surfaces in pickers, action sheets, and the calibration tour.
///
/// Resolution order (highest to lowest):
///   1. Active VehicleProfile's `overrideLabel` — the per-trim
///      friendlier name baked into `CarProfile` (e.g. "Driver" for
///      the cluster on L8 / L5L).
///   2. Hand-rolled aliases for raw names that ship in every BYD
///      ROM (`fse` → "Passenger Screen").
///   3. Cluster-role catch-all (`role == 'cluster'` or `isCluster`).
///   4. Raw `Display.name`, falling back to `Display N`.
///
/// Two callers historically rolled their own copy of this:
/// `mini_app_actions_sheet.dart` (with an `(id=N)` suffix) and
/// `display_drop_picker.dart` (clean label). The suffix is now an
/// optional parameter so both call sites can share one source —
/// when BYD ships a new trim with a new alias, we update one
/// function instead of grepping for two near-duplicates.
String displayHumanLabel(DisplaySnapshot d, {bool includeIdSuffix = false}) {
  final base = _baseLabel(d);
  if (!includeIdSuffix) return base;
  // Some labels already encode the id (the "Display N" fallback);
  // don't double-print it.
  if (base.startsWith('Display ')) return base;
  return '$base (id=${d.id})';
}

String _baseLabel(DisplaySnapshot d) {
  final override = d.overrideLabel;
  if (override != null && override.isNotEmpty) return override;
  if (d.name.toLowerCase() == 'fse') return 'Passenger Screen';
  if (d.role == 'cluster' || d.isCluster) return 'Driver Cluster';
  return d.name.isEmpty ? 'Display ${d.id}' : d.name;
}
