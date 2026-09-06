import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import 'command.dart';

/// Registry fragment: read-only status commands.
///
/// `car.status` replaces the old hardcoded `car_state` helper in
/// [ToolHandler]. Keeping status inside the registry means voice + WS +
/// quick actions all discover "how do I read car state" via the same
/// manifest — no parallel code path.
final List<CarCommand> statusCommands = [
  const CarCommand(
    id: 'car.status',
    label: 'CAR STATUS',
    icon: Icons.info_outline_rounded,
    color: AppColors.neutral,
    category: CommandCategory.status,
  ),
];
