import 'dart:io';

import 'package:ilink/features/_car_domain/command/action_ids.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contract test: the Dart [ActionIds] class and the Kotlin `ActionIds.kt`
/// mirror must declare the same set of action id strings. Reads the Kotlin
/// file as text and regex-extracts `const val <name> = "<value>"` pairs so
/// drift is caught at CI time without needing a Kotlin test harness.
void main() {
  group('ActionIds Dart↔Kotlin contract', () {
    final kotlinFile = File(
      'android/app/src/main/kotlin/com/i99dev/ilink/car/ActionIds.kt',
    );
    late Map<String, String> kotlinIds;

    setUpAll(() {
      expect(
        kotlinFile.existsSync(),
        isTrue,
        reason:
            'Kotlin mirror missing at ${kotlinFile.path} — tests must run '
            'from the dash/ directory so relative paths resolve.',
      );
      final source = kotlinFile.readAsStringSync();
      final re = RegExp(
        r'const\s+val\s+(\w+)\s*=\s*"([^"]+)"',
        multiLine: true,
      );
      kotlinIds = {
        for (final m in re.allMatches(source)) m.group(1)!: m.group(2)!,
      };
    });

    test('Kotlin file parses a non-empty set', () {
      expect(
        kotlinIds,
        isNotEmpty,
        reason: 'ActionIds.kt has no const vals — parser regex broke?',
      );
    });

    test('every Dart ActionIds.all entry exists on Kotlin with same value', () {
      final missing = <String>[];
      for (final id in ActionIds.all) {
        if (!kotlinIds.values.contains(id)) missing.add(id);
      }
      expect(missing, isEmpty, reason: 'Dart ids absent on Kotlin: $missing');
    });

    test('every Kotlin const val is listed in Dart ActionIds.all', () {
      final stray = kotlinIds.values.where((v) => !ActionIds.all.contains(v));
      expect(
        stray,
        isEmpty,
        reason: 'Kotlin ids absent from Dart: ${stray.toList()}',
      );
    });

    test('Dart constant names match Kotlin const names 1:1', () {
      // Read the Dart source too so we compare symbol names, not just values.
      // Catches the case where the string value matches but the constant
      // was renamed on only one side.
      final dartFile = File('lib/features/_car_domain/command/action_ids.dart');
      expect(dartFile.existsSync(), isTrue);
      final dartSource = dartFile.readAsStringSync();
      final dartRe = RegExp(
        r"static\s+const\s+String\s+(\w+)\s*=\s*'([^']+)'",
        multiLine: true,
      );
      final dartIds = {
        for (final m in dartRe.allMatches(dartSource)) m.group(1)!: m.group(2)!,
      };
      expect(dartIds, isNotEmpty);

      // Same set of names on both sides — ensures the conventions stay
      // aligned even if someone renames one side.
      expect(
        dartIds.keys.toSet(),
        kotlinIds.keys.toSet(),
        reason: 'constant name sets diverge',
      );

      // Values must match per name as well.
      for (final k in dartIds.keys) {
        expect(
          dartIds[k],
          kotlinIds[k],
          reason: 'value for $k differs between Dart and Kotlin',
        );
      }
    });
  });

  group('CarTableSource coverage', () {
    test(
      'every canonical ActionIds entry exists in the public local table',
      () {
        final table = File(
          'android/app/src/main/assets/offline/car_table.textproto',
        );
        expect(
          table.existsSync(),
          isTrue,
          reason: 'Public table must ship on every checkout.',
        );
        final ids = RegExp(
          r'action_id:\s*"([^"]+)"',
        ).allMatches(table.readAsStringSync()).map((m) => m.group(1)!).toList();
        expect(ids, isNotEmpty);
        expect(
          ids.toSet().length,
          ids.length,
          reason: 'No duplicate dispatch IDs.',
        );
        expect(ActionIds.all.toSet().difference(ids.toSet()), isEmpty);
        expect(ids.toSet().difference(ActionIds.all.toSet()), isEmpty);
      },
    );
  });
  group('ActionIds templated helpers', () {
    test('massage resolves only drv/co × mode/level', () {
      expect(ActionIds.massage('drv', 'mode'), ActionIds.massageDrvMode);
      expect(ActionIds.massage('drv', 'level'), ActionIds.massageDrvLevel);
      expect(ActionIds.massage('co', 'mode'), ActionIds.massageCoMode);
      expect(ActionIds.massage('co', 'level'), ActionIds.massageCoLevel);
      expect(ActionIds.massage('rl', 'mode'), isNull);
      expect(ActionIds.massage('drv', 'bogus'), isNull);
    });

    test('atmos resolves on/off/bright/color only', () {
      expect(ActionIds.atmos('on'), ActionIds.atmosOn);
      expect(ActionIds.atmos('off'), ActionIds.atmosOff);
      expect(ActionIds.atmos('bright'), ActionIds.atmosBright);
      expect(ActionIds.atmos('color'), ActionIds.atmosColor);
      expect(ActionIds.atmos('state'), isNull);
    });

    test('seatHeat resolves for all four seats', () {
      expect(ActionIds.seatHeat('drv'), ActionIds.heatDrvLevel);
      expect(ActionIds.seatHeat('pass'), ActionIds.heatPassLevel);
      expect(ActionIds.seatHeat('rl'), ActionIds.heatRearLeftLevel);
      expect(ActionIds.seatHeat('rr'), ActionIds.heatRearRightLevel);
      expect(ActionIds.seatHeat('middle'), isNull);
    });
  });
}
