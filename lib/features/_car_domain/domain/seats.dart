import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/catalog_command_builder.dart';
import '../command/command.dart';
import '../safety/rate_limiter.dart';

/// Seat heat / ventilation command fragment.
///
/// Post-Phase-4 (2026-05-14): heated seats (4 positions) + driver
/// ventilation come from the BYD catalog via [bydCatalogCommands].
/// Passenger + rear ventilation stay declared as bare const because
/// they route through the IAcSeat binder, not FAST UnitDispatcher —
/// no wire entry in the textproto on Leopard 8. When the binder
/// transport ships, add catalog rows for them and move them under
/// the overlay map below; `_knownDartOnly` in the parity test
/// exempts them until then.
///
/// Voice groups:
///   seat_heat(seat: drv|pass|rl|rr, value: 0-3)
///   seat_vent(seat: drv, value: 0-3)    — single-seat for now
const _heatGroup = 'seat_heat';
const _heatIdTemplate = 'seat.heat.{seat}';
const _heatGroupParams = {'seat': 'drv | pass | rl | rr', 'value': '0-3'};
const _heatGroupDescription =
    'Set heat level (0=off, 1=low, 2=med, 3=high) for any seat. '
    'Examples: "warm the driver seat" → seat=drv, value=2. '
    '"Max heat for the rear left seat" → seat=rl, value=3. '
    '"Turn off the passenger seat heat" → seat=pass, value=0.';

const _ventGroup = 'seat_vent';
const _ventIdTemplate = 'seat.vent.{seat}';
const _ventGroupParams = {'seat': 'drv', 'value': '0-3'};
const _ventGroupDescription =
    'Set ventilation level (0=off, 1=low, 2=med, 3=high) for the driver '
    'seat. Only the driver seat has vent on this car. '
    'Example: "cool the driver seat" → seat=drv, value=2.';

final List<CarCommand> seatCommands = [
  ...bydCatalogCommands(
    category: CommandCategory.comfort,
    // Predictive: every heat/vent level change is one-tap reversible
    // (set to 0 or another level); no physical motion. Letting these
    // fire ahead of TTS narration cuts ~150-300 ms of perceived
    // latency on the most-frequent comfort utterances.
    reversible: true,
    overlays: const {
      'seat_heat_drv': CommandOverlay(
        icon: Icons.thermostat_auto_rounded,
        color: AppColors.warning,
        label: 'DRV SEAT HEAT',
        voiceGroup: _heatGroup,
        voiceIdTemplate: _heatIdTemplate,
        voiceGroupParams: _heatGroupParams,
        voiceDescription: _heatGroupDescription,
      ),
      'seat_heat_pass': CommandOverlay(
        icon: Icons.thermostat_auto_rounded,
        color: AppColors.warning,
        label: 'PASS SEAT HEAT',
        voiceGroup: _heatGroup,
        voiceIdTemplate: _heatIdTemplate,
        voiceGroupParams: _heatGroupParams,
        voiceDescription: _heatGroupDescription,
      ),
      'seat_heat_rl': CommandOverlay(
        icon: Icons.thermostat_auto_rounded,
        color: AppColors.warning,
        label: 'REAR L SEAT HEAT',
        voiceGroup: _heatGroup,
        voiceIdTemplate: _heatIdTemplate,
        voiceGroupParams: _heatGroupParams,
        voiceDescription: _heatGroupDescription,
      ),
      'seat_heat_rr': CommandOverlay(
        icon: Icons.thermostat_auto_rounded,
        color: AppColors.warning,
        label: 'REAR R SEAT HEAT',
        voiceGroup: _heatGroup,
        voiceIdTemplate: _heatIdTemplate,
        voiceGroupParams: _heatGroupParams,
        voiceDescription: _heatGroupDescription,
      ),
      'seat_vent_drv': CommandOverlay(
        icon: Icons.air_rounded,
        color: AppColors.accent,
        label: 'DRV SEAT VENT',
        voiceGroup: _ventGroup,
        voiceIdTemplate: _ventIdTemplate,
        voiceGroupParams: _ventGroupParams,
        voiceDescription: _ventGroupDescription,
      ),
    },
  ),

  // ── Binder-path ventilation (no FAST wire). Trim-dependent: on
  //    cars without the ventilated rear-seat option, the IAcSeat
  //    binder returns null and the controller surfaces a typed
  //    failure. Not grouped with drv-vent because the two transports
  //    can't share a voice template.
  const CarCommand(
    id: 'seat.vent.pass',
    label: 'PASS SEAT VENT',
    icon: Icons.air_rounded,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: {'value': '0-3'},
    rateClass: RateClass.climate,
    reversible: true,
  ),
  const CarCommand(
    id: 'seat.vent.rl',
    label: 'REAR L SEAT VENT',
    icon: Icons.air_rounded,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: {'value': '0-3'},
    rateClass: RateClass.climate,
    reversible: true,
  ),
  const CarCommand(
    id: 'seat.vent.rr',
    label: 'REAR R SEAT VENT',
    icon: Icons.air_rounded,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: {'value': '0-3'},
    rateClass: RateClass.climate,
    reversible: true,
  ),
];
