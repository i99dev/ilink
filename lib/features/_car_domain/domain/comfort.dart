import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/command.dart';

/// Massage / fragrance / ambient-light command fragment.
///
/// **Pattern: arg-derived dispatch via `resolve:` closures.** Three
/// commands here (`comfort.massage`, `comfort.massage.off`,
/// `comfort.atmos`) compute the wire action_id at dispatch time from
/// the caller's args:
///
///   * `comfort.massage(seat, field, value)` → `massage.<seat>.<field>`
///   * `comfort.atmos(field, value)` → `comfort.atmos.<field>`
///
/// One voice tool / one registry id maps to N wire actions selected by
/// arg. The catalog-driven builder ([bydCatalogCommands]) is 1:1 and
/// doesn't fit; the `resolve:` closure is the canonical shape for
/// arg-dispatched commands.
///
/// The two simple cases (`comfort.frag.on/off`) use Phase-2 identity:
/// bare const, registry id == wire id, no resolve needed.
///
/// Every command here is `reversible: true` — massage, fragrance and
/// atmosphere lighting are all one-tap revertible (user can say "off"
/// or pick another mode/level). Predictive dispatch fires them
/// alongside TTS narration, cutting ~150-300 ms of perceived latency
/// on the most-frequent comfort utterances.
final List<CarCommand> comfortCommands = [
  CarCommand(
    id: 'comfort.massage',
    label: 'MASSAGE',
    icon: Icons.spa,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: const {'seat': 'drv | co', 'field': 'mode | level', 'value': 'int'},
    paramDefaults: const {'seat': 'drv', 'field': 'mode', 'value': 1},
    voiceDescription:
        'Massage chair control. seat=drv (driver) or co (front '
        'passenger). field=mode (pattern) or level (intensity). '
        'For mode: 1=off, 2 and 3 are vendor patterns. For level: 0-3 '
        '(0=stop, 3=strongest). To stop a massage prefer the '
        'comfort.massage.off tool — it has no args and is unambiguous.',
    // Daemon's action_id is `massage.<seat>.<field>` (massage.drv.mode,
    // massage.co.level, …). The cmd-level alias `comfort.massage`
    // doesn't exist in the action table; the resolver builds the real id.
    resolve: (args) => (
      actionId: 'massage.${args['seat'] ?? 'drv'}.${args['field'] ?? 'mode'}',
      args: {'value': args['value'] ?? 1},
    ),
    reversible: true,
  ),
  CarCommand(
    id: 'comfort.massage.off',
    label: 'MASSAGE OFF',
    icon: Icons.spa_outlined,
    color: AppColors.neutral,
    category: CommandCategory.comfort,
    params: const {'seat': 'drv | co'},
    paramDefaults: const {'seat': 'drv'},
    voiceDescription:
        'Stop the massage on a seat. seat=drv (default) or co. Use '
        'this whenever the user says "turn off massage" / "stop '
        'massage" — it dispatches the BYD-specific off enum so the '
        'state actually changes (sending value=0 to comfort.massage '
        'is a no-op on this vendor).',
    // BYD off enum: seat-mode set to 1 = idle.
    resolve: (args) => (
      actionId: 'massage.${args['seat'] ?? 'drv'}.mode',
      args: const {'value': 1},
    ),
    reversible: true,
  ),
  // Post-Phase-2: textproto renamed `frag.on/off` → `comfort.frag.on/off`
  // and `atmos.<field>` → `comfort.atmos.<field>`. The frag resolves
  // collapse to identity (deleted); atmos still needs a resolve
  // because the `field` arg picks WHICH of the four atmos action_ids
  // to dispatch (on/off/bright/color).
  CarCommand(
    id: 'comfort.frag.on',
    label: 'FRAGRANCE',
    icon: Icons.local_florist,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: const {'level': '1-3'},
    paramDefaults: const {'level': 2},
    voiceDescription:
        'Turn on cabin fragrance. level=1 (light), 2 (medium, default), '
        '3 (strong). For "turn off" use comfort.frag.off.',
    // `level` is the LLM-facing param name; the wire takes `value`.
    resolve: (args) =>
        (actionId: 'comfort.frag.on', args: {'value': args['level'] ?? 2}),
    reversible: true,
  ),
  const CarCommand(
    id: 'comfort.frag.off',
    label: 'FRAGRANCE OFF',
    icon: Icons.local_florist_outlined,
    color: AppColors.neutral,
    category: CommandCategory.comfort,
    reversible: true,
  ),
  CarCommand(
    id: 'comfort.atmos',
    label: 'AMBIENT',
    icon: Icons.auto_awesome,
    color: AppColors.accent,
    category: CommandCategory.comfort,
    params: const {'field': 'on | off | bright | color', 'value': 'int'},
    resolve: (args) => (
      actionId: 'comfort.atmos.${args['field'] ?? 'on'}',
      args: args['value'] != null ? {'value': args['value']} : const {},
    ),
    reversible: true,
  ),
];
