import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import 'command.dart';

/// Registry fragment: app-launcher command definitions.
///
/// Not a hardware domain — these launch OTHER Android apps on the car via the
/// shell bridge (`am start` / `monkey`, see
/// `features/apps/app_voice_dispatch.dart`), not a car binder. They live in
/// the same registry so the voice subagent can discover them.
///
/// **Voice shape.** The main voice model does NOT see these as individual
/// tools — every entry is `voiceHidden: true`. It sees one
/// `app_launcher(query)` tool exposed by [DelegatingToolRouter], which
/// forwards the driver's natural-language request ("play jazz on YouTube",
/// "take me home") to a cheap text subagent that selects and calls one of
/// these directly — keeping the app-launch surface out of the main session's
/// token budget (same pattern as `radio_assistant`).
///
/// `requiresStationary` stays false: launching a media/navigation app is the
/// app's own concern (it shows its own driving-safety UI), exactly like the
/// radio domain.
const List<CarCommand> appCommands = [
  CarCommand(
    id: 'app.open',
    label: 'OPEN APP',
    icon: Icons.open_in_new_rounded,
    color: AppColors.secondary,
    category: CommandCategory.apps,
    // Spoken app name, e.g. "YouTube", "WhatsApp". Resolved to a package by
    // the dispatcher (catalog first, then installed-package match).
    params: {'app': 'string'},
    voiceHidden: true,
  ),
  CarCommand(
    id: 'app.search',
    label: 'PLAY / SEARCH IN APP',
    icon: Icons.search_rounded,
    color: AppColors.accent,
    category: CommandCategory.apps,
    // e.g. {app: "YouTube", query: "jazz"} → open YouTube searching jazz.
    params: {'app': 'string', 'query': 'string'},
    voiceHidden: true,
  ),
  CarCommand(
    id: 'app.navigate',
    label: 'NAVIGATE',
    icon: Icons.navigation_rounded,
    color: AppColors.accent,
    category: CommandCategory.apps,
    // destination is required; app is optional (defaults to the maps app).
    // "home"/"work" pass through verbatim so the maps app resolves them
    // against the driver's own saved places.
    params: {'destination': 'string', 'app': 'string'},
    paramDefaults: {'app': ''},
    voiceHidden: true,
  ),
];
