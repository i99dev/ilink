/// navigate_to panel — fires the nav-app geo intent on show and shows a
/// brief confirming side panel that auto-dismisses. (The action is the
/// hand-off; the panel is just confirmation.)
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/voice/domain/voice_tool_def.dart';
import 'package:ilink/features/nav_hud/application/nav_hud_controller.dart';
import 'geo_launch.dart';
import 'voice_result_models.dart';
import 'voice_side_panel.dart';

Future<void> showVoiceNavigatePanel(
  BuildContext context,
  VoiceToolDef tool,
  Map<String, dynamic> args,
) async {
  final result = NavigateResult.fromArgs(args);

  // Fire-and-forget hand-off; the panel just confirms.
  if (result.canLaunch) {
    unawaited(
      launchGeoIntent(lat: result.lat!, lng: result.lng!, label: result.label),
    );
    // Auto-arm the cluster Nav-HUD (opt-in; respects the autoStart option).
    unawaited(_maybeArmNavHud(context));
  }

  await showVoiceSidePanel<void>(
    context,
    autoDismiss: const Duration(seconds: 4),
    child: _NavigateConfirm(result: result),
  );
}

/// Arm the cluster Nav-HUD when navigation starts, if the user enabled
/// auto-start. Best-effort: the HUD is optional, so any failure is swallowed.
Future<void> _maybeArmNavHud(BuildContext context) async {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    final ctrl = container.read(navHudControllerProvider.notifier);
    if (container.read(navHudControllerProvider).options.autoStart) {
      await ctrl.setEnabled(true);
    }
  } catch (_) {
    // nav-HUD not available on this build/car — ignore.
  }
}

class _NavigateConfirm extends StatelessWidget {
  const _NavigateConfirm({required this.result});
  final NavigateResult result;

  @override
  Widget build(BuildContext context) {
    final degraded = result.status.degraded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoicePanelHeader(
          icon: degraded
              ? Icons.error_outline_rounded
              : Icons.navigation_rounded,
          title: degraded
              ? "Couldn't start navigation"
              : 'Navigating to ${result.label}',
          subtitle: degraded ? result.status.message : 'Opening your nav app…',
        ),
      ],
    );
  }
}
