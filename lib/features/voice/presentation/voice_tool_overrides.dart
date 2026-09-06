/// Per-tool custom UI builder registry — wires each backend display
/// tool to its rich side panel (see ``widgets/voice_side_panel.dart``).
///
/// Mount: `_AppShell` reads [voiceToolOverridesProvider] once at build
/// time so every registration runs before the first voice session
/// mints. Provider returns void; the side effect is the static-map
/// entries on [SheetInteractivePrompter]. Registering is idempotent —
/// re-watching during a hot-reload overwrites the same key.
///
/// Adding a new override:
///   1. Build the panel content (one file in ``widgets/``) exposing a
///      ``Future<void> show…Panel(context, tool, args)`` that calls
///      ``showVoiceSidePanel``.
///   2. Add a one-line ``registerDisplay(...)`` below.
///   3. Backend opts the tool's ``ui_hint`` into ``display``.
///
/// Tools without a custom builder fall back to the generic display
/// sheet, so an opt-in cadence is fine.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sheet_interactive_prompter.dart';
import 'widgets/voice_navigate_panel.dart';
import 'widgets/voice_places_panel.dart';
import 'widgets/voice_route_panel.dart';
import 'widgets/voice_translate_panel.dart';
import 'widgets/voice_weather_panel.dart';

void _registerAllOverrides() {
  // Place results — list of cards + per-card navigate + tap→detail.
  SheetInteractivePrompter.registerDisplay('find_nearby', showVoicePlacesPanel);
  SheetInteractivePrompter.registerDisplay('find_place', showVoicePlacesPanel);
  // Single-destination tools.
  SheetInteractivePrompter.registerDisplay('get_route', showVoiceRoutePanel);
  SheetInteractivePrompter.registerDisplay(
    'navigate_to',
    showVoiceNavigatePanel,
  );
  // Glanceable info.
  SheetInteractivePrompter.registerDisplay(
    'get_weather',
    showVoiceWeatherPanel,
  );
  SheetInteractivePrompter.registerDisplay(
    'translate',
    showVoiceTranslatePanel,
  );
}

/// Riverpod accessor — watched once from `_AppShell.build()`. Returns
/// void; the only purpose is to run [_registerAllOverrides] once per
/// provider container lifetime.
final voiceToolOverridesProvider = Provider<void>((_) {
  _registerAllOverrides();
});
