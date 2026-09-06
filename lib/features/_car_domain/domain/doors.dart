import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/command.dart';
import '../safety/rate_limiter.dart';

/// Door / hood command fragment.
///
/// **Pattern: bare-const, no catalog overlay.** Every command here is a
/// pure write trigger with no useful read-state counterpart in the
/// catalog: `door.lock` / `door.unlock` write the BYD four-door bulk
/// key (`Bodywork.BODYWORK_FOUR_DOOR_SET`), `door.trunk.*` write the
/// luggage actuator, `hood.*` write the forecabin actuator. The
/// per-door read state lives in `lock_lf` / `door_lf` / `trunk`
/// catalog rows, but those are 1:N to the actuator commands — the
/// catalog-driven builder ([bydCatalogCommands]) assumes 1:1 and
/// doesn't fit. Bare-const + Phase-2 identity (registry id IS the
/// textproto action_id) is the canonical shape for trigger-only
/// commands.
///
/// Adding a new door command after Phase 4:
///   1. Add a `fast_actions { action_id: "..." }` row to the textproto.
///   2. Add a bare-const [CarCommand] here with the same id.
///   3. `registry_wire_parity_test` guarantees the bridge stays correct.
///
/// Hood shares this file because it's a body-closure command with the
/// same safety / UX treatment (stationary-only, warning color).
const _hoodGroup = 'hood_control';
const _hoodIdTemplate = 'hood.{action}';
const _hoodGroupParams = {'action': 'open | close | stop'};
const _hoodGroupDescription =
    'Open, close, or stop the hood (frunk). Only available at a standstill. '
    'Examples: "open the hood" → action=open, "stop the hood" → action=stop.';

final List<CarCommand> doorCommands = [
  const CarCommand(
    id: 'door.lock',
    label: 'LOCK',
    icon: Icons.lock_rounded,
    color: AppColors.primary,
    category: CommandCategory.door,

    // Reversible — user can re-unlock immediately. Predictive
    // executor fires ahead of TTS confirmation per the plan table.
    reversible: true,
  ),
  const CarCommand(
    id: 'door.unlock',
    label: 'UNLOCK',
    icon: Icons.lock_open_rounded,
    color: AppColors.accent,
    category: CommandCategory.door,
    requiresStationary: true,
    // Security-sensitive: a background trigger must carry explicit
    // confirmation before the engine unlocks the car.
    securityClass: SecurityClass.security,
  ),
  // Post-Phase-2: registry id IS the wire id; textproto renamed
  // `trunk.*` → `door.trunk.*` so the dispatch lands directly.
  const CarCommand(
    id: 'door.trunk.open',
    label: 'TRUNK OPEN',
    icon: Icons.luggage_rounded,
    color: AppColors.warning,
    category: CommandCategory.door,
    requiresStationary: true,
    securityClass: SecurityClass.safety,
  ),
  const CarCommand(
    id: 'door.trunk.close',
    label: 'TRUNK CLOSE',
    icon: Icons.luggage,
    color: AppColors.primary,
    category: CommandCategory.door,
    requiresStationary: true,
    securityClass: SecurityClass.safety,
  ),

  // ── Hood (frunk). Shares BODY 0x4C110020; grouped for voice. ──
  const CarCommand(
    id: 'hood.open',
    label: 'HOOD OPEN',
    icon: Icons.directions_car_filled_outlined,
    color: AppColors.warning,
    category: CommandCategory.door,
    requiresStationary: true,
    securityClass: SecurityClass.safety,
    rateClass: RateClass.actuator,

    voiceGroup: _hoodGroup,
    voiceIdTemplate: _hoodIdTemplate,
    voiceGroupParams: _hoodGroupParams,
    voiceDescription: _hoodGroupDescription,
  ),
  const CarCommand(
    id: 'hood.close',
    label: 'HOOD CLOSE',
    icon: Icons.directions_car_filled,
    color: AppColors.primary,
    category: CommandCategory.door,
    requiresStationary: true,
    securityClass: SecurityClass.safety,
    rateClass: RateClass.actuator,

    voiceGroup: _hoodGroup,
    voiceIdTemplate: _hoodIdTemplate,
    voiceGroupParams: _hoodGroupParams,
    voiceDescription: _hoodGroupDescription,
  ),
  const CarCommand(
    id: 'hood.stop',
    label: 'HOOD STOP',
    icon: Icons.stop_circle_outlined,
    color: AppColors.neutral,
    category: CommandCategory.door,
    requiresStationary: true,
    securityClass: SecurityClass.safety,
    rateClass: RateClass.actuator,

    voiceGroup: _hoodGroup,
    voiceIdTemplate: _hoodIdTemplate,
    voiceGroupParams: _hoodGroupParams,
    voiceDescription: _hoodGroupDescription,
  ),
];
