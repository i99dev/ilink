import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../data/installed_mini_app_store.dart';
import '../domain/mini_app.dart';
import '../domain/mini_app_compat.dart';
import '../state/mini_app_compat_target.dart';
import 'beta_consent_sheet.dart';
import 'mini_app_viewer.dart';
import 'mini_app_install_consent.dart';

/// Entry point for launching any mini-app. The driver-safety gate
/// previously blocked non-`safeWhileDriving` apps while the car was in
/// motion; per product call (2026-05-01), drivers may open any mini-app
/// at any time. The viewer no longer pops on drive-away either — see
/// `mini_app_viewer.dart` for the matching change.
Future<void> openMiniApp(
  BuildContext context,
  WidgetRef ref,
  MiniApp app,
) async {
  // Vehicle-compat gate (host-side defense in depth). The backend
  // catalog already hides incompatible apps, but a stale catalog
  // cache must not launch an app THIS car can't run. Uses the exact
  // same evaluator as the SDK + backend (`evaluateCompatibility`,
  // single source of truth) so the answer can never drift; fail-
  // closed by construction. Runs FIRST — no point updating/installing
  // an app the car can't execute. `requires == null` (the common
  // "runs anywhere" case) returns ok in O(1) — zero overhead.
  final target = await ref.read(miniAppCompatTargetProvider.future);
  if (!context.mounted) return;
  final compat = evaluateCompatibility(app.requires, target);
  if (!compat.ok) {
    developer.log(
      'mini-app ${app.id} blocked: ${compat.reasons.map((r) => '${r.code.name}: ${r.detail}').join(' | ')}',
      name: 'openMiniApp',
    );
    await _showIncompatibleDialog(context);
    return;
  }

  // Auto-update check: compare catalog SHA against the recorded
  // installed SHA. On mismatch, beta builds prompt (testers may want
  // to capture state before the update); production builds re-install
  // silently and surface a toast. Privileged apps fall through — the
  // privileged orchestrator re-verifies the cert on every install.
  if (!context.mounted) return;

  // For beta builds, show the one-time consent sheet before proceeding.
  // The sheet persists consent per (userId, appId, version) so it only
  // appears on first launch of each beta build, not on every tap.
  if (app.isBeta) {
    final consented = await showBetaConsentIfNeeded(context, ref, app);
    if (!consented) return;
    if (!context.mounted) return;
  }

  // Resolve the on-disk index.html before pushing — the viewer
  // refuses to render without a verified local install. If it's
  // missing (catalog says installed but bundle was wiped manually
  // or by a partial uninstall), show an actionable error instead of
  // a blank WebView.
  final localIndexPath = await ref
      .read(installedMiniAppStoreProvider)
      .indexHtmlPath(app.id);
  if (!context.mounted) return;
  if (localIndexPath == null) {
    await _showNotInstalledDialog(context);
    return;
  }
  if (!await ensureMiniAppLaunchConsent(context, ref, app, localIndexPath) ||
      !context.mounted) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MiniAppViewer(app: app, localIndexPath: localIndexPath),
    ),
  );
}

/// Catalog/installed SHA-mismatch handler. Returns true when the launch
/// can proceed (no update needed, OR the update completed). Returns
/// false when the user dismissed the prompt — caller bails on the
/// launch and the existing install stays untouched.
///
/// Privileged apps short-circuit: the privileged orchestrator handles
/// cert + cap re-verification on every install, so falling back to a
/// silent re-install path on mismatch is safe but redundant — let the
/// user explicitly tap Install again from the modal in that case.
Future<void> _showNotInstalledDialog(BuildContext context) {
  final t = S.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.download_for_offline_outlined),
      // Reuses the generic "couldn't open" copy — the user-actionable
      // recovery is the same: pull-to-refresh the Store + reinstall.
      content: Text(t.miniAppsCouldNotOpen),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.miniAppsDrivingBlockedOk),
        ),
      ],
    ),
  );
}

/// Shown when the vehicle-compat gate refuses an app on this car
/// (`requires` not met — wrong DiLink, missing capability, WebView
/// too old, bridge too old, or an unsupported newer schema). Mirrors
/// [_showNotInstalledDialog]: reuses the generic, already-localized
/// "couldn't open" copy in every locale rather than shipping
/// machine-translated per-reason strings — the precise machine reason
/// is logged for triage (see `openMiniApp`), and the user-actionable
/// outcome is identical ("this app won't run here"). Map
/// `CompatReason.code` to localized per-reason copy here if product
/// later wants reason-specific messaging.
Future<void> _showIncompatibleDialog(BuildContext context) {
  final t = S.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.directions_car_outlined),
      content: Text(t.miniAppsCouldNotOpen),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.miniAppsDrivingBlockedOk),
        ),
      ],
    ),
  );
}
