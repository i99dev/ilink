import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import 'command.dart';

/// Registry fragment: radio-domain command definitions.
///
/// Not a hardware domain — these drive the in-app player (see
/// `features/radio/radio_controller.dart`), not the car binders. They live
/// in the same registry as door/climate/etc. so the WebSocket dispatcher
/// and quick-action tiles route to them without branching.
///
/// **Voice shape.** The main voice model does NOT see these as individual
/// tools — every entry is `voiceHidden: true`. Instead, it sees one
/// `radio_assistant(query)` tool exposed by [DelegatingToolRouter], which
/// forwards the user's natural-language query to a cheap text subagent
/// that selects and calls one of these commands directly. This keeps the
/// radio's intent-heavy surface ("play jazz from France", "something
/// calmer") out of the main session's token budget.
///
/// `requiresStationary` stays false for all radio commands — audio
/// control is always safe at speed.
// Radio commands switch a software audio stream the driver can
// flip away from instantly — all reversible. Predictive executor
// fires station / play / pause changes ahead of TTS confirmation.
final List<CarCommand> radioCommands = _radioRaw
    .map((c) => c.withReversible(true))
    .toList(growable: false);

final List<CarCommand> _radioRaw = [
  const CarCommand(
    id: 'radio.play_by_name',
    label: 'PLAY RADIO',
    icon: Icons.radio_rounded,
    color: AppColors.accent,
    category: CommandCategory.radio,
    params: {'name': 'string'},

    voiceHidden: true,
  ),
  const CarCommand(
    id: 'radio.play_station',
    label: 'PLAY STATION',
    icon: Icons.play_arrow_rounded,
    color: AppColors.primary,
    category: CommandCategory.radio,
    params: {'station_id': 'string'},

    voiceHidden: true,
  ),
  const CarCommand(
    id: 'radio.pause',
    label: 'PAUSE',
    icon: Icons.pause_rounded,
    color: AppColors.primary,
    category: CommandCategory.radio,

    voiceHidden: true,
  ),
  const CarCommand(
    id: 'radio.resume',
    label: 'RESUME',
    icon: Icons.play_arrow_rounded,
    color: AppColors.primary,
    category: CommandCategory.radio,

    voiceHidden: true,
  ),
  const CarCommand(
    id: 'radio.stop',
    label: 'STOP RADIO',
    icon: Icons.stop_rounded,
    color: AppColors.primary,
    category: CommandCategory.radio,

    voiceHidden: true,
  ),
  const CarCommand(
    id: 'radio.next_fav',
    label: 'NEXT FAV',
    icon: Icons.skip_next_rounded,
    color: AppColors.accent,
    category: CommandCategory.radio,

    voiceHidden: true,
  ),
];
