import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/catalog_command_builder.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/safety/rate_limiter.dart';

/// Phase 4 builder unit tests.
///
/// Validates that `bydCatalogCommands` produces sane [CarCommand]
/// instances when given a real catalog + UI overlays. The point is
/// to lock in the heuristic for params / defaults / labels so a
/// future catalog edit can't silently shift the registry's UI
/// contract.
void main() {
  group('bydCatalogCommands', () {
    test('builds climate.temp from catalog with range-derived params', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.climate,
        overlays: {
          'ac_target_temp': const CommandOverlay(
            icon: Icons.thermostat,
            color: Color(0xFF2EA66B),
            voiceDescription: 'Set cabin temperature.',
          ),
        },
        reversible: true,
      );
      expect(cmds, hasLength(1));
      final cmd = cmds.single;
      expect(cmd.id, 'climate.temp', reason: 'should use wireActionId');
      expect(cmd.category, CommandCategory.climate);
      expect(cmd.icon, Icons.thermostat);
      expect(cmd.params, {'value': '16-32'});
      expect(cmd.paramDefaults, {'value': 24});
      expect(cmd.reversible, true);
      expect(cmd.voiceDescription, 'Set cabin temperature.');
    });

    test('derives bool params when description contains "(0 off, 1 on)"', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.climate,
        overlays: {
          'ac_power': const CommandOverlay(
            icon: Icons.power_settings_new_rounded,
            color: Color(0xFF2EA66B),
          ),
        },
      );
      expect(cmds.single.id, 'climate.power');
      expect(cmds.single.params, {'on': 'bool'});
    });

    test('derives default label from snake_case signal name', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.climate,
        overlays: {
          'ac_target_temp': const CommandOverlay(
            icon: Icons.thermostat,
            color: Color(0xFF2EA66B),
          ),
        },
      );
      expect(cmds.single.label, 'AC TARGET TEMP');
    });

    test('honours explicit label override on the overlay', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.climate,
        overlays: {
          'ac_target_temp': const CommandOverlay(
            icon: Icons.thermostat,
            color: Color(0xFF2EA66B),
            label: 'CLIMATE TEMP',
          ),
        },
      );
      expect(cmds.single.label, 'CLIMATE TEMP');
    });

    test('forwards voice group + rate class from overlay', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.comfort,
        overlays: {
          'seat_heat_drv': const CommandOverlay(
            icon: Icons.thermostat_auto_rounded,
            color: Color(0xFFE6A057),
            voiceGroup: 'seat_heat',
            voiceIdTemplate: 'seat.heat.{seat}',
            voiceGroupParams: {'seat': 'drv | pass | rl | rr', 'value': '0-3'},
            rateClass: RateClass.climate,
            requiresStationary: false,
          ),
        },
      );
      final cmd = cmds.single;
      expect(cmd.id, 'seat.heat.drv');
      expect(cmd.voiceGroup, 'seat_heat');
      expect(cmd.voiceIdTemplate, 'seat.heat.{seat}');
      expect(cmd.voiceGroupParams!['seat'], 'drv | pass | rl | rr');
      expect(cmd.rateClass, RateClass.climate);
    });

    test('throws on unknown overlay key (drift detection)', () {
      expect(
        () => bydCatalogCommands(
          category: CommandCategory.climate,
          overlays: {
            'this_signal_does_not_exist': const CommandOverlay(
              icon: Icons.thermostat,
              color: Color(0xFF2EA66B),
            ),
          },
        ),
        throwsStateError,
      );
    });

    test('throws on catalog entry without wireActionId', () {
      // Pick a writeable catalog signal that doesn't have wireActionId
      // populated yet (Phase 3 backfill TODO list — printed by the
      // catalog parity test). `seat_vent_pass` is in that list and
      // has `writeable: true` + writeAction but no wireActionId.
      expect(
        () => bydCatalogCommands(
          category: CommandCategory.comfort,
          overlays: {
            'seat_vent_pass': const CommandOverlay(
              icon: Icons.air_rounded,
              color: Color(0xFF2EA66B),
            ),
          },
        ),
        throwsStateError,
      );
    });

    test('builds multiple commands in the same call, preserving order', () {
      final cmds = bydCatalogCommands(
        category: CommandCategory.climate,
        overlays: {
          'ac_power': const CommandOverlay(
            icon: Icons.power_settings_new_rounded,
            color: Color(0xFF2EA66B),
          ),
          'ac_target_temp': const CommandOverlay(
            icon: Icons.thermostat,
            color: Color(0xFF2EA66B),
          ),
          'ac_fan': const CommandOverlay(
            icon: Icons.air,
            color: Color(0xFF2EA66B),
          ),
        },
      );
      expect(cmds.map((c) => c.id), [
        'climate.power',
        'climate.temp',
        'climate.fan',
      ]);
    });
  });
}
