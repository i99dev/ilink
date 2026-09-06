import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';

/// Locks the [SecurityClass] tagging of the command registry. This is
/// the FIRST-CLASS safety signal the workflow engine gates background
/// dispatch on — distinct from `reversible` (which is a voice-prediction
/// hint and is `true` for door.unlock + windows). A mis-tag here would
/// let a background automation fire a hazardous actuator while moving.
void main() {
  group('CarCommand.securityClass tagging', () {
    test(
      'door.unlock is security-class (needs confirmation, not just stationary)',
      () {
        expect(
          commandById('door.unlock')!.securityClass,
          SecurityClass.security,
        );
      },
    );

    test('trunk + hood are safety-class', () {
      for (final id in [
        'door.trunk.open',
        'door.trunk.close',
        'hood.open',
        'hood.close',
        'hood.stop',
      ]) {
        expect(
          commandById(id)!.securityClass,
          SecurityClass.safety,
          reason: id,
        );
      }
    });

    test(
      'every window + sunroof command is safety-class — including close/stop',
      () {
        final motion = commandRegistry.values.where(
          (c) => c.id.startsWith('window.') || c.id.startsWith('sunroof.'),
        );
        expect(motion, isNotEmpty);
        for (final c in motion) {
          expect(c.securityClass, SecurityClass.safety, reason: c.id);
        }
      },
    );

    test('comfort / climate / light / radio commands stay none', () {
      for (final c in commandRegistry.values) {
        final isComfortish =
            c.category == CommandCategory.climate ||
            c.category == CommandCategory.light ||
            c.category == CommandCategory.comfort ||
            c.category == CommandCategory.radio;
        if (isComfortish) {
          expect(c.securityClass, SecurityClass.none, reason: c.id);
        }
      }
    });

    test(
      'INVARIANT: any command flagged requiresStationary is classified non-none',
      () {
        // If the legacy gate says "unsafe while moving", the new
        // first-class field must agree — catches a command that set the
        // stationary flag but was never given a security class.
        final misTagged = commandRegistry.values
            .where(
              (c) =>
                  c.requiresStationary && c.securityClass == SecurityClass.none,
            )
            .map((c) => c.id)
            .toList();
        expect(
          misTagged,
          isEmpty,
          reason: 'requiresStationary but securityClass.none: $misTagged',
        );
      },
    );

    test('withSecurityClass clones without disturbing other fields', () {
      final base = commandById('door.lock')!;
      final tagged = base.withSecurityClass(SecurityClass.safety);
      expect(tagged.securityClass, SecurityClass.safety);
      expect(tagged.id, base.id);
      expect(tagged.reversible, base.reversible);
      expect(tagged.requiresStationary, base.requiresStationary);
    });
  });
}
