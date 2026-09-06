import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/climate.dart';
import '../domain/comfort.dart';
import '../domain/doors.dart';
import '../domain/lights.dart';
import '../domain/seats.dart';
import '../domain/windows.dart';
import 'app_commands.dart';
import 'command.dart';
import 'radio_commands.dart';
import 'status_commands.dart';

/// Assembles every domain's command fragment into a single flat registry.
/// Adding a new domain = `import` + one spread entry here; adding a new
/// command inside an existing domain stays in that domain's fragment.
///
/// Frozen once at first access via [Map.unmodifiable]; consumers share the
/// same instance so `ref.read(commandRegistryProvider)` never reallocates.
///
/// **One namespace policy** (since the 2026-05-13 command methodology
/// redesign):
/// every routable [CarCommand.id] MUST be a wire action id that the
/// encrypted table declares as a `fast_actions { action_id: ... }`,
/// `unit_actions { action_id: ... }`, or `macros { macro_id: ... }`
/// entry. The router dispatches `cmd.id` verbatim — no alias map,
/// no per-command transform.
///
/// Drift is enforced two ways:
///   - CI: `test/features/_car_domain/command/registry_wire_parity_test.dart`.
///   - Boot: `BootSequence._warnOnCommandDrift` logs unroutable ids.
///
/// Exceptions (deliberately Dart-only, allowlisted in the parity test):
///   - `radio.*` commands — handled in-app, never cross the bridge.
///   - `app.*` commands — launch other Android apps via the shell bridge
///     (`am start`), never the encrypted action table.
///   - `car.status` — special-cased in the command router.
///
/// [CarCommand.resolve] is a transitional escape hatch retained while
/// the textproto migration to `macros {}` blocks is in flight (Phase 2
/// of the methodology doc). New commands MUST NOT add `resolve:`;
/// instead, add a `macros {}` row to the textproto and let `cmd.id`
/// match `macro_id`.
final Map<String, CarCommand> commandRegistry = Map.unmodifiable({
  for (final c in [
    ...doorCommands,
    ...climateCommands,
    ...lightCommands,
    ...comfortCommands,
    ...windowCommands,
    ...seatCommands,
    ...radioCommands,
    ...statusCommands,
    ...appCommands,
  ])
    c.id: c,
});

CarCommand? commandById(String id) => commandRegistry[id];

Iterable<CarCommand> commandsByCategory(CommandCategory c) =>
    commandRegistry.values.where((cmd) => cmd.category == c);

final commandRegistryProvider = Provider<Map<String, CarCommand>>(
  (_) => commandRegistry,
);
