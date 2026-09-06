import 'display_snapshot.dart';

/// One source of truth for "which displays should the picker show, and
/// which should be hidden?" — kept separate from the wire-shape model
/// so a UI convention change (e.g. the policy reversion from
/// dim-don't-hide back to hide) ships as a one-file edit instead of
/// touching every picker.
///
/// Why this isn't on [DisplaySnapshot] directly:
///   * The snapshot is the wire contract — pure data, no UI policy.
///   * Picker policy (which surfaces appear, in what order, dimmed
///     or hidden) belongs to the consumer; embedding it in the wire
///     type would couple every SDK consumer to dashboard-side UX
///     choices.
///   * Splitting also means tests for visibility live in
///     `mini_apps/runtime/display_visibility_test.dart` without
///     re-exercising the snapshot's JSON shape.
///
/// **DiLink 5.0 vs 5.1 contract** (this is the safety rail):
///   * Di5.0 (L5 / Song PLUS): the VehicleProfile flags shadow /
///     pointer-only cluster panels in its `hiddenDisplayIds`; on
///     the wire these surface as a non-null `dimReason`. The picker
///     drops them so the operator only sees the canonical Driver
///     surface (the hidden layer is reserved for the cursor overlay).
///   * Di5.1 (L8 / L5L / L5U): same — `hiddenDisplayIds = {3, 4}`
///     means displays 3 (mirror of 5) and 4 (cursor overlay layer)
///     are dropped from the picker; only display 5 ("Driver") is
///     a valid app target.
///
/// History: an interim revision routed shadows to the END of the
/// picker as dim cards instead of dropping them, on the theory that
/// firmware variation might make a "shadow" actually reachable. In
/// practice the dim cards confused operators (they tried to drop
/// apps there and got silent failures), so the policy reverted —
/// dimReason now means HIDE again. The deprecated [hidden] bool is
/// honoured identically for back-compat with hosts that haven't
/// shipped the dimReason payload.

extension DisplayVisibilityX on DisplaySnapshot {
  /// True when the active VehicleProfile flags this display as a
  /// duplicate / shadow surface. Pickers should render with reduced
  /// opacity + the [dimReason] subtitle — they should NOT drop the
  /// display from the list.
  ///
  /// Reads `dimReason` first (the new contract) and falls back to
  /// the deprecated `hidden` flag for back-compat with hosts that
  /// haven't been re-rolled with the dim-reason payload yet.
  bool get isDimmed => dimReason != null || hidden;

  /// Optional explanation string for the dim state — typically
  /// something like `"mirrors Display 5"` or `"vendor-gated"`. Null
  /// when [isDimmed] is false OR when the host shipped before the
  /// `dimReason` field existed (the [hidden]-only legacy case).
  /// Callers append this to their own subtitle text with a `· `
  /// separator for the standard picker look.
  String? get dimSubtitle => dimReason;
}

extension DisplayListVisibilityX on Iterable<DisplaySnapshot> {
  /// Ordered list for picker rendering. By default, displays the
  /// active profile flags as dimmed (via `dimReason` or the legacy
  /// `hidden` bool) are DROPPED — operators only see the canonical
  /// targets, and the hidden layers (e.g. L8's display 3 mirror + 4
  /// cursor-overlay layer) stay out of the way. Set
  /// [includeDimmed] = true for debug / calibration surfaces that
  /// still need every Android Display the OS reports.
  ///
  /// Ordering preserves the input order. [excludeDefault] drops the
  /// IVI (`isDefault == true`) — used by the mini-app actions sheet
  /// which has a separate "Open here" entry.
  ///
  /// History: an earlier revision routed dimmed surfaces to the end
  /// of the list instead of dropping them, to handle firmware
  /// variations where a "shadow" might actually be reachable. The
  /// trade-off (operator confusion about silent-failing tiles)
  /// proved worse than the trade-off it was avoiding (no escape
  /// hatch for a mis-profiled trim), so the policy reverted. If a
  /// future trim genuinely needs the shadow exposed, set
  /// `hiddenDisplayIds = emptySet()` on its profile — that's the
  /// single seam.
  List<DisplaySnapshot> forPicker({
    bool excludeDefault = false,
    bool includeDimmed = false,
  }) {
    final out = <DisplaySnapshot>[];
    for (final d in this) {
      if (excludeDefault && d.isDefault) continue;
      if (d.isDimmed && !includeDimmed) continue;
      out.add(d);
    }
    return List.unmodifiable(out);
  }

  /// Strictly-active subset for classifier / auto-seed pipelines that
  /// should ignore shadow surfaces (e.g. the calibration auto-seed —
  /// no point labelling a display that mirrors another).
  ///
  /// **Not for picker UI** — picker UI must call [forPicker] instead.
  List<DisplaySnapshot> classifierInput() =>
      List.unmodifiable(where((d) => !d.isDimmed));
}
