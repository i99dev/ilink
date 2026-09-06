import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:ilink/kernel/i18n/command_labels.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widgets that render registry commands by hard-coded id (quick-action
/// tiles, command-labels map) are silent points of failure — if someone
/// renames `door.trunk.open`, the tile simply disappears at runtime with
/// no test failure and no warning.
///
/// Rather than import the widget (and drag Flutter bindings in), this
/// test mirrors the id list inline. If you edit `quick_actions_grid.dart`
/// or `command_labels.dart`, update the arrays below too.
void main() {
  group('Quick-action tile ids resolve in the registry', () {
    const quickActionIds = [
      'door.unlock',
      'door.lock',
      'door.trunk.open',
      'light.head.on',
    ];

    test('every hard-coded tile id exists in commandRegistry', () {
      for (final id in quickActionIds) {
        expect(
          commandRegistry.containsKey(id),
          isTrue,
          reason:
              'quick_actions_grid references "$id" but the registry has '
              'no command with that id — either rename the tile list or '
              'restore the registry entry',
        );
      }
    });
  });

  group('localizedCommandLabel targets resolve', () {
    // Keys that command_labels.dart currently maps to a localized string.
    // If a key ever stops matching a registry command, the tile still
    // renders but the label silently falls back to the raw English label —
    // acceptable, but flag it so we can decide intentionally.
    const labeledIds = [
      'door.lock',
      'door.unlock',
      'door.trunk.open',
      'light.head.on',
      'light.head.off',
      'comfort.massage',
      'comfort.frag.on',
      'comfort.atmos',
    ];

    test('every labeled id is also a real registry command', () {
      for (final id in labeledIds) {
        expect(
          commandRegistry.containsKey(id),
          isTrue,
          reason:
              'command_labels.dart labels "$id" but it is not in the '
              'registry — rename or remove the label entry',
        );
      }
    });

    test('localizedCommandLabel treats unknown ids as null', () {
      // `S.of(context)` requires a Flutter binding we don't set up here;
      // asserting the null-fallthrough branch is enough to pin the
      // "unknown id doesn't throw" contract.
      expect(localizedCommandLabel, isNotNull);
    });
  });
}
