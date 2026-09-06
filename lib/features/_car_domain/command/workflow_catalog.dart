/// Serializes the command registry into the ACTION palette consumed by
/// the workflow canvas (over the `workflow.catalog` bridge handler).
///
/// `car.list` deliberately returns readable SIGNALS only — the writable
/// command registry has no other bridge surface, so this is the one
/// gap-fill the canvas needs to offer actions. Each entry carries the
/// safety flags (`securityClass` / `requiresStationary` / `rateClass` /
/// `reversible`) the canvas uses to badge + confirm dangerous nodes and
/// the on-car engine uses to derive its independent stationary/confirm
/// gate — NEVER from `reversible` alone (see [SecurityClass]).
///
/// Pure (registry in → JSON-ready list out) so it unit-tests without a
/// `ProviderContainer`. Mirrors the SDK wire shape in `ilink-sdk`
/// `types/workflow.ts` (`WorkflowActionEntrySchema` /
/// `WorkflowCatalogResponseSchema`).
library;

import '../safety/rate_limiter.dart';
import 'command.dart';

/// Schema version of the `workflow.catalog` payload. Independent of the
/// `WorkflowDocument` schema; bump if the entry shape changes. Mirrors
/// `WORKFLOW_CATALOG_SCHEMA` in the SDK.
const int kWorkflowCatalogSchema = 1;

/// Categories that are NOT user-authorable actions and so are excluded
/// from the palette: `status` is a read (`car.status`), `raw` is an
/// internal escape hatch.
const Set<CommandCategory> _excludedCategories = <CommandCategory>{
  CommandCategory.status,
  CommandCategory.raw,
};

/// Canonical wire form of a [RateClass], matching the SDK's
/// `RATE_CLASSES` enum (`statusRead` → `'status_read'`).
String? rateClassWire(RateClass? r) => switch (r) {
  RateClass.actuator => 'actuator',
  RateClass.climate => 'climate',
  RateClass.light => 'light',
  RateClass.statusRead => 'status_read',
  RateClass.media => 'media',
  null => null,
};

/// Build the flat list of action-palette entries from [registry],
/// sorted by id for a stable wire order. Excludes read/internal
/// categories; everything else (door/climate/light/window/comfort/
/// seat/radio/app) is offered with its metadata + safety flags.
List<Map<String, Object?>> workflowActionEntries(
  Map<String, CarCommand> registry,
) {
  final entries = <Map<String, Object?>>[];
  for (final cmd in registry.values) {
    if (_excludedCategories.contains(cmd.category)) continue;
    entries.add(<String, Object?>{
      'id': cmd.id,
      'label': cmd.label,
      'category': cmd.category.name,
      if (cmd.params.isNotEmpty) 'params': cmd.params,
      if (cmd.paramDefaults.isNotEmpty) 'paramDefaults': cmd.paramDefaults,
      'requiresStationary': cmd.requiresStationary,
      'reversible': cmd.reversible,
      'securityClass': cmd.securityClass.name,
      'rateClass': rateClassWire(cmd.rateClass),
      if (cmd.voiceGroup != null) 'voiceGroup': cmd.voiceGroup,
      if (cmd.voiceGroupParams != null)
        'voiceGroupParams': cmd.voiceGroupParams,
    });
  }
  entries.sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));
  return entries;
}
