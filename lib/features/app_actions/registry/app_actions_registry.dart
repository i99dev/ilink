import 'package:flutter/material.dart';

import '../../../kernel/registry/action_def.dart';
import '../domain/app_action.dart';
import '../domain/app_meta.dart';
import '../domain/app_target.dart';

/// **Single source of truth for the app-actions sheet.**
///
/// One row per action. The sheet renders circles by iterating this
/// list; nothing else cares about action identity. Adding action #8
/// = one row + one icon + one l10n key.
final List<ActionDef<AppTarget, AppMeta>> kAppActionsRegistry = [
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.enable.name,
    iconBuilder: (_, _) => const Icon(Icons.toggle_on_outlined),
    labelKey: 'appActionEnable',
    severity: ActionSeverity.safe,
    eligible: (m) => !m.enabled,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.disable.name,
    iconBuilder: (_, _) => const Icon(Icons.toggle_off_outlined),
    labelKey: 'appActionDisable',
    severity: ActionSeverity.confirm,
    confirmKey: 'appActionDisableConfirmBody',
    eligible: (m) => m.enabled,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.uninstall.name,
    iconBuilder: (_, _) => const Icon(Icons.delete_outline),
    labelKey: 'appActionUninstall',
    // Single-tap confirm (no typed token). Uninstall on this head
    // unit is recoverable — re-installing from the BYD store / sideload
    // is a known motion, and the eligibility gate (`canUninstall`)
    // already excludes system packages we can't reinstall.
    severity: ActionSeverity.confirm,
    confirmKey: 'appActionUninstallConfirmBody',
    eligible: (m) => m.canUninstall,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.transferRunning.name,
    iconBuilder: (_, _) => const Icon(Icons.swap_horiz_rounded),
    labelKey: 'appActionTransfer',
    severity: ActionSeverity.safe,
    eligible: (m) => m.runningTaskId != null,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.forceStop.name,
    iconBuilder: (_, _) => const Icon(Icons.stop_circle_outlined),
    labelKey: 'appActionForceStop',
    severity: ActionSeverity.safe,
    eligible: (m) => m.runningTaskId != null,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.clearData.name,
    iconBuilder: (_, _) => const Icon(Icons.cleaning_services_outlined),
    labelKey: 'appActionClearData',
    severity: ActionSeverity.typedConfirm,
    confirmKey: 'appActionClearDataConfirmBody',
    typedToken: 'CLEAR',
    eligible: (m) => true,
  ),
  ActionDef<AppTarget, AppMeta>(
    id: AppActionKind.whitelist.name,
    iconBuilder: (_, _) => const Icon(Icons.verified_user_outlined),
    labelKey: 'appActionWhitelist',
    severity: ActionSeverity.safe,
    eligible: (m) => !m.inDozeWhitelist,
  ),
];

/// Maps a registry id back to its [AppActionKind] — single indirection
/// so the dispatch path doesn't enumerate strings.
AppActionKind kindFromId(String id) =>
    AppActionKind.values.firstWhere((k) => k.name == id);
