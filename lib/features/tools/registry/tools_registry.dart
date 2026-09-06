import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/workflow/domain/workflow_summary.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/settings/app_settings.dart';
import '../../../sdk/car/providers.dart' show daemonReadyProvider;
import '../../nav_hud/application/nav_hud_controller.dart';
import '../../workflow/data/workflow_providers.dart';
import '../../shortcuts/presentation/floating_shortcuts_sheet.dart';
import '../../workflow/presentation/workflow_control_sheet.dart';
import '../domain/connectivity_state.dart';
import '../domain/tool.dart';
import '../presentation/sheets/doctor_sheet.dart';
import '../presentation/sheets/nav_hud_sheet.dart';
import '../presentation/sheets/network_mode_sheet.dart';
import '../state/connectivity_state_provider.dart';

/// **Single source of truth for the Tools strip.**
///
/// Adding a tool:
///   1. Add a kind to [ToolKind].
///   2. Add a `Tool(...)` row below.
///   3. Drop a section file in `presentation/sheets/`.
///   4. Add `tools_<kind>_label` to en + ar arb.
///
/// That's it. The Tools strip iterates this list; nothing else
/// references individual tools by identity.
final List<Tool> kToolsRegistry = [
  Tool(
    kind: ToolKind.network,
    iconBuilder: (ctx) => const Icon(Icons.network_check_rounded, size: 24),
    labelKey: 'tools_network_label',
    sheetBuilder: (ctx) => const NetworkModeSheet(),
    ringStatusFor: _networkRing,
  ),
  Tool(
    kind: ToolKind.doctor,
    iconBuilder: (ctx) => const Icon(Icons.troubleshoot_rounded, size: 24),
    labelKey: 'tools_doctor_label',
    sheetBuilder: (ctx) => const DoctorSheet(),
    ringStatusFor: _doctorRing,
  ),
  Tool(
    kind: ToolKind.fab,
    iconBuilder: (ctx) => const Icon(Icons.apps_rounded, size: 24),
    labelKey: 'tools_fab_label',
    sheetBuilder: (ctx) => const FloatingShortcutsSheet(),
    ringStatusFor: _fabRing,
  ),
  Tool(
    kind: ToolKind.navHud,
    iconBuilder: (ctx) => const Icon(Icons.pin_drop_rounded, size: 24),
    labelKey: 'tools_nav_hud_label',
    sheetBuilder: (ctx) => const NavHudSheet(),
    ringStatusFor: _navHudRing,
  ),
  Tool(
    kind: ToolKind.workflow,
    iconBuilder: (ctx) => const Icon(Icons.bolt_rounded, size: 24),
    labelKey: 'tools_workflow_label',
    sheetBuilder: (ctx) => const WorkflowControlSheet(),
    ringStatusFor: _workflowRing,
  ),
];

ToolStatusRing _workflowRing(WidgetRef ref) {
  final workflows = ref.watch(
    localWorkflowDigestProvider.select(
      (a) => a.value ?? const <WorkflowSummary>[],
    ),
  );
  if (workflows.isEmpty) return ToolStatusRing.offline;
  return workflows.any((w) => w.enabled)
      ? ToolStatusRing.online
      : ToolStatusRing.offline;
}

/// FAB ring lights green when at least one app is pinned as a floating
/// button (the buttons are live over every screen); gray when none are.
ToolStatusRing _fabRing(WidgetRef ref) {
  final pinned = ref.watch(
    settingsProvider.select(
      (s) => s.value?.floatingAppShortcuts.isNotEmpty ?? false,
    ),
  );
  return pinned ? ToolStatusRing.online : ToolStatusRing.offline;
}

/// Nav-HUD ring lights green when the cluster HUD is armed (driving turn-by-turn
/// onto the instrument cluster), gray when off. Reads the same controller state
/// the sheet toggles, scoped to `armed` so the strip only rebuilds on that flip.
ToolStatusRing _navHudRing(WidgetRef ref) {
  final armed = ref.watch(navHudControllerProvider.select((s) => s.armed));
  return armed ? ToolStatusRing.online : ToolStatusRing.offline;
}

/// Doctor ring mirrors daemon readiness — green when the car-control
/// service is up (voice actions work), gray when it's down (the user can
/// tap in and wake it). The most user-actionable signal for this tool.
ToolStatusRing _doctorRing(WidgetRef ref) {
  final async = ref.watch(daemonReadyProvider);
  return async.when(
    loading: () => ToolStatusRing.unknown,
    error: (_, _) => ToolStatusRing.offline,
    data: (up) => up ? ToolStatusRing.online : ToolStatusRing.offline,
  );
}

ToolStatusRing _networkRing(WidgetRef ref) {
  final async = ref.watch(connectivityStateProvider);
  return async.when(
    loading: () => ToolStatusRing.unknown,
    error: (_, _) => ToolStatusRing.unknown,
    data: (s) {
      // If anything is transitioning, surface that — it's the most
      // user-actionable signal.
      const transitioning = NetState.transitioning;
      if (s.wifi == transitioning ||
          s.bluetooth == transitioning ||
          s.cellular == transitioning ||
          s.hotspot == transitioning) {
        return ToolStatusRing.transitioning;
      }
      return s.hasAnyOnline ? ToolStatusRing.online : ToolStatusRing.offline;
    },
  );
}

/// Maps a [Tool.labelKey] to the live localized string. Single
/// indirection point so a typo in a registry row blows up loudly
/// in `tools_registry_validation_test.dart` instead of silently
/// surfacing the raw key in the UI.
String resolveToolLabel(BuildContext context, String key) {
  final s = S.of(context);
  return switch (key) {
    'tools_network_label' => s.toolsNetworkLabel,
    'tools_doctor_label' => s.toolsDoctorLabel,
    'tools_fab_label' => s.toolsFabLabel,
    'tools_nav_hud_label' => s.toolsNavHudLabel,
    'tools_workflow_label' => s.toolsWorkflowLabel,
    _ => key,
  };
}
