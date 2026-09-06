/// Phase 4 — catalog-driven [CarCommand] builder.
///
/// The catalog (`byd_catalog.dart`) is the single authored source of
/// truth for action ids, wire mappings, and value ranges. Domain
/// files (`climate.dart`, `doors.dart`, ...) now describe ONLY the
/// UI / voice overlay — icon, color, voice description, requires-
/// stationary, rate class.
///
/// Adding a new command after Phase 4:
///   1. Add the row to `byd_catalog.dart` (writeable, wireActionId).
///   2. Add a [CommandOverlay] entry to the relevant domain file
///      keyed by the catalog signal name.
///
/// The CI parity tests guarantee the bridge stays correct:
///   * `registry_wire_parity_test.dart` — every registry id is a
///     textproto action_id.
///   * `byd_catalog_wire_parity_test.dart` — every catalog
///     wireActionId is a textproto action_id.
library;

import 'package:flutter/material.dart';

import '../../../sdk/brands/byd/byd_catalog.dart';
import '../../../sdk/car/public_catalog.dart';
import '../safety/rate_limiter.dart';
import 'command.dart';

/// Per-signal UI overlay supplied by the domain file. The catalog
/// owns id / params / wire mapping; the overlay owns icon / color /
/// voice description / per-command UX (requiresStationary, rateClass).
class CommandOverlay {
  const CommandOverlay({
    required this.icon,
    required this.color,
    this.label,
    this.voiceDescription,
    this.requiresStationary = false,
    this.rateClass,
    this.voiceGroup,
    this.voiceIdTemplate,
    this.voiceGroupParams,
    this.voiceHidden = false,
    this.paramDefaultsOverride,
  });

  final IconData icon;
  final Color color;

  /// Display label override. When null, derived from the catalog
  /// signal name (`ac_target_temp` → `AC TARGET TEMP`).
  final String? label;

  /// Voice tool description. When null, the voice manifest skips
  /// this command's per-instance description (UI-only). Voice can
  /// still surface it via [voiceGroup] templating.
  final String? voiceDescription;

  final bool requiresStationary;
  final RateClass? rateClass;
  final String? voiceGroup;
  final String? voiceIdTemplate;
  final Map<String, String>? voiceGroupParams;
  final bool voiceHidden;

  /// Domain-file override for the param defaults the builder would
  /// otherwise derive from the catalog range (mid-point). Use when
  /// the legacy command shipped a specific default that doesn't
  /// match the midpoint (e.g. `climate.temp` shipped `22` on
  /// range 16-32; midpoint would be 24). `null` means "let the
  /// builder derive from the catalog".
  final Map<String, Object>? paramDefaultsOverride;
}

/// Build a list of [CarCommand] for [category] from the BYD catalog,
/// applying caller-supplied [overlays] keyed by catalog signal name.
///
/// Contract:
///   * Each key in [overlays] MUST be a catalog signal name. Unknown
///     keys throw [StateError] — drift detected at build time.
///   * The matched catalog entry MUST have a non-null `wireActionId`.
///     Missing wire id throws — Phase 3 backfill is required first.
///   * [reversible] is bulk-applied via [CarCommand.withReversible] —
///     matches the per-domain pattern in climate.dart / windows.dart.
///
/// Param derivation:
///   * `range: IntRange(min, max)` → `params: {'value': '$min-$max'}`
///     with midpoint default.
///   * No range and description hints at a boolean → `{'on': 'bool'}`.
///   * Otherwise empty params (caller supplies via voice group).
///
/// **Note**: this function does NOT mutate the catalog or registry.
/// `BydPublicCatalog.build()` is memoised (process-wide), so the
/// several domain files that call this at registry-init share one
/// catalog instead of each re-walking ~6k entries. Callers still don't
/// need to thread a `PublicCatalog` reference.
List<CarCommand> bydCatalogCommands({
  required CommandCategory category,
  required Map<String, CommandOverlay> overlays,
  bool reversible = false,
  PublicCatalog? catalogOverride,
}) {
  final catalog = catalogOverride ?? BydPublicCatalog.build();
  final out = <CarCommand>[];
  for (final entry in overlays.entries) {
    final sigName = entry.key;
    final overlay = entry.value;
    final cat = catalog.get(sigName);
    if (cat == null) {
      throw StateError(
        'bydCatalogCommands: overlay key "$sigName" is not in the '
        'BYD catalog. Add a _Sig row to byd_catalog.dart or fix '
        'the overlay key.',
      );
    }
    if (cat.wireActionId == null) {
      throw StateError(
        'bydCatalogCommands: catalog entry "$sigName" has no '
        'wireActionId — Phase 3 backfill required. See '
        'docs/sdk/_plans/phase4-registry-codegen.md.',
      );
    }
    final params = _paramsForEntry(cat);
    final paramDefaults =
        overlay.paramDefaultsOverride ?? _paramDefaultsForEntry(cat);
    final cmd = CarCommand(
      id: cat.wireActionId!,
      label: overlay.label ?? _labelFromName(cat.name),
      icon: overlay.icon,
      color: overlay.color,
      category: category,
      params: params,
      paramDefaults: paramDefaults,
      requiresStationary: overlay.requiresStationary,
      rateClass: overlay.rateClass,
      voiceGroup: overlay.voiceGroup,
      voiceIdTemplate: overlay.voiceIdTemplate,
      voiceGroupParams: overlay.voiceGroupParams,
      voiceDescription: overlay.voiceDescription,
      voiceHidden: overlay.voiceHidden,
    );
    out.add(reversible ? cmd.withReversible(true) : cmd);
  }
  return List.unmodifiable(out);
}

/// Build the UI/voice `params` map from a catalog entry's `range` +
/// description. Heuristic-driven — every Phase 4 migration should
/// verify the generated params match what the pre-Phase-4 domain
/// file declared. The fixture in
/// `test/features/_car_domain/command/catalog_command_builder_test.dart`
/// pins the heuristic against the live catalog so future catalog
/// edits don't silently shift param shapes.
Map<String, String> _paramsForEntry(PublicCatalogEntry e) {
  if (e.range != null) {
    return {'value': '${e.range!.min}-${e.range!.max}'};
  }
  if (e.description.toLowerCase().contains('(0 off, 1 on)') ||
      e.description.toLowerCase().contains('state (0 off, 1 on)')) {
    return const {'on': 'bool'};
  }
  return const {};
}

Map<String, Object> _paramDefaultsForEntry(PublicCatalogEntry e) {
  if (e.range != null) {
    // Midpoint default. Legacy domain files sometimes used a value
    // different from the catalog midpoint (e.g. climate.temp's
    // default was 22 on range 16-32 — midpoint is 24); migrations
    // that need the legacy default supply it via the overlay or
    // adjust the catalog range. The midpoint is the right default
    // for new commands.
    final mid = (e.range!.min + e.range!.max) ~/ 2;
    return <String, Object>{'value': mid};
  }
  return const {};
}

/// Derive a default label from a catalog signal name: snake_case →
/// SHOUTY SPACED ("ac_target_temp" → "AC TARGET TEMP").
String _labelFromName(String name) {
  return name.replaceAll('_', ' ').toUpperCase();
}
