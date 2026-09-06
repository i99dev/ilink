import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Invariants for the flat command registry. Keeps domain fragments from
/// silently clashing or losing coverage after an edit.
void main() {
  test('registry ids are unique', () {
    final ids = commandRegistry.keys.toList();
    expect(
      ids.toSet().length,
      ids.length,
      reason: 'duplicate command ids: ${_dupes(ids)}',
    );
  });

  test('every command has non-empty id + label', () {
    for (final cmd in commandRegistry.values) {
      expect(cmd.id, isNotEmpty);
      expect(cmd.label, isNotEmpty);
    }
  });

  test('every declared category has at least one command', () {
    // raw + status are reserved for future use — skip.
    const user = {
      CommandCategory.door,
      CommandCategory.climate,
      CommandCategory.comfort,
      CommandCategory.light,
      CommandCategory.window,
    };
    for (final cat in user) {
      expect(
        commandsByCategory(cat),
        isNotEmpty,
        reason: 'no commands in category $cat',
      );
    }
  });

  test('commandRegistry is unmodifiable', () {
    expect(
      () => commandRegistry['x'] = commandRegistry.values.first,
      throwsUnsupportedError,
    );
  });

  test('commandById returns the same instance as the map lookup', () {
    for (final id in commandRegistry.keys.take(5)) {
      expect(identical(commandById(id), commandRegistry[id]), isTrue);
    }
  });

  test('param hints follow the documented mini-grammar', () {
    final pipe = RegExp(r'^\w+(\s*\|\s*\w+)+$');
    final range = RegExp(r'^\-?\d+\s*-\s*\-?\d+$');
    const atomic = {'int', 'integer', 'bool', 'boolean', 'string'};
    for (final cmd in commandRegistry.values) {
      for (final hint in cmd.params.values) {
        final h = hint.trim();
        final ok = atomic.contains(h) || pipe.hasMatch(h) || range.hasMatch(h);
        expect(
          ok,
          isTrue,
          reason:
              'command ${cmd.id} param hint "$hint" is not int/bool/range/enum — '
              'update _propSchema in tool_handler.dart or fix the hint',
        );
      }
    }
  });
}

List<String> _dupes(List<String> xs) {
  final seen = <String>{};
  final out = <String>{};
  for (final x in xs) {
    if (!seen.add(x)) out.add(x);
  }
  return out.toList();
}
