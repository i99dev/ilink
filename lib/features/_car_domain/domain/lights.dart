import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/catalog_command_builder.dart';
import '../command/command.dart';

/// Exterior lights command fragment.
///
/// Post-Phase-4 (2026-05-14): the six toggleable signals (head /
/// head.on / fog_f / fog_r / turn_left / turn_right) come from the
/// BYD catalog via [bydCatalogCommands]. The three remaining
/// commands stay as bare const declarations because they have no
/// catalog write-signal:
///
///   * `light.head.off` — explicit off; the catalog's `low_beam`
///     toggle covers `light.head.on` but there's no symmetric
///     off-signal row.
///   * `light.flash` / `light.find_car` — momentary triggers; no
///     state signal in the catalog to attach to.
///
/// Adding catalog rows for these is a Phase 3 follow-up (the
/// catalog parity test won't surface them because they don't yet
/// carry `writeable: true`).
///
/// Voice shape:
///   light.head(on: bool)                 — single parameterized headlight tool
///   fog_lights(position: f|r, on: bool)  — group over both fog variants
///
/// The `light.head.on` / `light.head.off` ids stay in the registry because
/// the home-screen quick-actions grid is keyed to them, but they are
/// `voiceHidden` so the voice model only sees one headlight tool.
/// Turn signals / flash / find-car stay as individual commands — no useful
/// grouping dimension.
const _headlightsDescription =
    'Turn the headlights on or off. Examples: "turn on the headlights" '
    '→ on=true. "Lights off" → on=false.';

const _fogGroup = 'fog_lights';
const _fogIdTemplate = 'light.fog_{position}';
const _fogGroupParams = {'position': 'f | r', 'on': 'bool'};
const _fogGroupDescription =
    'Toggle front (position=f) or rear (position=r) fog lights. '
    'Examples: "turn on the front fog lights" → position=f, on=true. '
    '"Rear fog off" → position=r, on=false.';

final List<CarCommand> lightCommands = [
  ...bydCatalogCommands(
    category: CommandCategory.light,
    reversible: true,
    overlays: const {
      'high_beam': CommandOverlay(
        icon: Icons.lightbulb_outline_rounded,
        color: AppColors.secondary,
        label: 'HEADLIGHTS',
        voiceDescription: _headlightsDescription,
      ),
      'low_beam': CommandOverlay(
        icon: Icons.lightbulb_outline_rounded,
        color: AppColors.secondary,
        label: 'HEADLIGHTS',
        voiceHidden: true,
      ),
      'front_fog': CommandOverlay(
        icon: Icons.foggy,
        color: AppColors.secondary,
        label: 'FRONT FOG',
        voiceGroup: _fogGroup,
        voiceIdTemplate: _fogIdTemplate,
        voiceGroupParams: _fogGroupParams,
        voiceDescription: _fogGroupDescription,
      ),
      'rear_fog': CommandOverlay(
        icon: Icons.foggy,
        color: AppColors.secondary,
        label: 'REAR FOG',
        voiceGroup: _fogGroup,
        voiceIdTemplate: _fogIdTemplate,
        voiceGroupParams: _fogGroupParams,
        voiceDescription: _fogGroupDescription,
      ),
      'turn_left': CommandOverlay(
        icon: Icons.arrow_back_rounded,
        color: AppColors.warning,
        label: 'LEFT SIGNAL',
      ),
      'turn_right': CommandOverlay(
        icon: Icons.arrow_forward_rounded,
        color: AppColors.warning,
        label: 'RIGHT SIGNAL',
      ),
    },
  ),

  // ── Bare-const: no catalog signal to attach to (off / momentary
  //    triggers). Dispatch via cmd.id directly; wire ids are in the
  //    textproto. Move under the overlay map above once a catalog
  //    row with writeable + wireActionId lands per command. ──
  const CarCommand(
    id: 'light.head.off',
    label: 'LIGHTS OFF',
    icon: Icons.lightbulb,
    color: AppColors.neutral,
    category: CommandCategory.light,
    voiceHidden: true,
    reversible: true,
  ),
  const CarCommand(
    id: 'light.flash',
    label: 'FLASH',
    icon: Icons.flash_on_rounded,
    color: AppColors.warning,
    category: CommandCategory.light,
    reversible: true,
  ),
  const CarCommand(
    id: 'light.find_car',
    label: 'FIND CAR',
    icon: Icons.rocket_launch_rounded,
    color: AppColors.accent,
    category: CommandCategory.light,
    reversible: true,
  ),
];
