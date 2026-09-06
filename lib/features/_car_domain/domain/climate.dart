import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/catalog_command_builder.dart';
import '../command/command.dart';
import '../safety/rate_limiter.dart';

/// Climate fragment of the command registry.
///
/// Post-Phase-4 (2026-05-14): registry commands are built from the
/// catalog via [bydCatalogCommands]. The overlay below supplies only
/// the per-command UI/voice metadata (icon, color, voice description,
/// rate class). Action ids, params, and wire mapping all come from
/// `byd_catalog.dart` — adding a new climate command after this
/// commit is one row in the catalog + one overlay entry here.
///
/// Two commands stay bare-const-declared because they're binder-only
/// on Leopard 8 (no FAST wire path; `_knownDartOnly` exempts them
/// from the parity test): `climate.comfort_mode` and
/// `climate.rear_lock`. When the binder transport ships, add catalog
/// rows for them and move them under the overlay map below.
final List<CarCommand> climateCommands = [
  ...bydCatalogCommands(
    category: CommandCategory.climate,
    reversible: true,
    overlays: const {
      'ac_power': CommandOverlay(
        icon: Icons.power_settings_new_rounded,
        color: AppColors.accent,
        label: 'CLIMATE POWER',
      ),
      'ac_target_temp': CommandOverlay(
        icon: Icons.thermostat,
        color: AppColors.accent,
        label: 'CLIMATE TEMP',
        // Legacy default — midpoint of the 16-32 range would be 24
        // but the legacy command shipped 22 °C. Preserve.
        paramDefaultsOverride: {'value': 22},
        voiceDescription:
            'Set cabin temperature in °C (range 16-32). Default 22°C when '
            'the user just says "make it warmer/cooler" without a number — '
            'use the current setpoint as a hint and pick within ±2°C.',
      ),
      'ac_fan': CommandOverlay(
        icon: Icons.air,
        color: AppColors.accent,
        label: 'CLIMATE FAN',
        voiceDescription:
            'Set fan speed (0=off, 1=low … 7=max). Default 3 (medium) when '
            'the user says "turn on the fan" without specifying.',
      ),
      'ac_wind_mode': CommandOverlay(
        icon: Icons.ac_unit_rounded,
        color: AppColors.accent,
        label: 'WIND MODE',
        // Legacy default — midpoint of 1-4 is 2, legacy shipped 1
        // (face).
        paramDefaultsOverride: {'value': 1},
        voiceDescription:
            'Set airflow direction mode (1=face, 2=face+feet, 3=feet, '
            '4=defrost+feet). Default 1 (face) for "set climate mode" with '
            'no further hint.',
      ),
      'ac_cycle': CommandOverlay(
        icon: Icons.loop_rounded,
        color: AppColors.accent,
        label: 'AIR CYCLE',
        // Legacy default 1 (recirculate); range 0-1 midpoint is 0.
        paramDefaultsOverride: {'value': 1},
        voiceDescription:
            'Set air recirculation (0=fresh outside air, 1=recirculate cabin '
            'air). Default 1 (recirculate).',
      ),
      'ac_defrost_f': CommandOverlay(
        icon: Icons.wb_sunny_outlined,
        color: AppColors.warning,
        label: 'FRONT DEFROST',
      ),
      'ac_defrost_r': CommandOverlay(
        icon: Icons.wb_sunny_outlined,
        color: AppColors.warning,
        label: 'REAR DEFROST',
      ),
      'ac_compressor': CommandOverlay(
        icon: Icons.ac_unit,
        color: AppColors.accent,
        label: 'AC COMPRESSOR',
        rateClass: RateClass.climate,
      ),
      'ac_max_hot': CommandOverlay(
        icon: Icons.local_fire_department_rounded,
        color: AppColors.warning,
        label: 'MAX HOT',
        rateClass: RateClass.climate,
      ),
      'ac_max_cool': CommandOverlay(
        icon: Icons.severe_cold_rounded,
        color: AppColors.accent,
        label: 'MAX COOL',
        rateClass: RateClass.climate,
      ),
    },
  ),
  // ── Binder-only — no FAST wire path on Leopard 8. _knownDartOnly
  //    in the parity test exempts these until acTransact is wired.
  const CarCommand(
    id: 'climate.comfort_mode',
    label: 'COMFORT MODE',
    icon: Icons.auto_awesome_mosaic_outlined,
    color: AppColors.accent,
    category: CommandCategory.climate,
    params: {'on': 'bool'},
    rateClass: RateClass.climate,
  ),
  const CarCommand(
    id: 'climate.rear_lock',
    label: 'REAR LOCK',
    icon: Icons.lock_outlined,
    color: AppColors.neutral,
    category: CommandCategory.climate,
    params: {'on': 'bool'},
    rateClass: RateClass.climate,
  ),
];
