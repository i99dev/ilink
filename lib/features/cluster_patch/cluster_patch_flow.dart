import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cluster_patch_bridge.dart';
import 'cluster_patch_terminal.dart';

/// The "native cast failed → offer to patch" remediation flow. Called from
/// the drop-card's hard-failure path. Native-first by construction: this
/// only runs after a native cluster cast has already been refused.
///
/// Captures the app-level [ScaffoldMessengerState] + [NavigatorState] up
/// front so the whole sequence (offer SnackBar → consent → progress →
/// result) survives the ephemeral drop card being torn down while a patch
/// is in flight.
Future<void> offerClusterPatch({
  required BuildContext context,
  required ProviderContainer container,
  required String packageName,
  required String label,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.maybeOf(context, rootNavigator: true);
  if (messenger == null || navigator == null) return;

  // Only offer for eligible (AMBER) apps — never for system/own (RED) or
  // already-patched (GREEN). Probe failures stay silent.
  final ProbeResult probe;
  try {
    probe = await container.read(clusterPatchBridgeProvider).probe(packageName);
  } catch (_) {
    return;
  }
  if (!probe.eligible) return;

  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text("Couldn't cast $label to the cluster."),
      action: SnackBarAction(
        label: 'Patch & retry',
        onPressed: () {
          // The action callback can't be async itself.
          unawaited(
            _confirmAndPatch(
              navigator,
              messenger,
              container,
              packageName,
              label,
            ),
          );
        },
      ),
    ),
  );
}

/// Explicit, user-initiated patch (the visible "Patch for cluster" button in
/// the Cluster-apps settings section). Unlike [offerClusterPatch] it is never
/// silent — it always gives feedback:
///   * RED   (system / own app) → a "can't patch" message
///   * GREEN  (already patched)  → offer to undo the patch
///   * AMBER  (eligible)         → consent → progress → result
Future<void> patchAppForCluster({
  required BuildContext context,
  required String packageName,
  required String label,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.maybeOf(context, rootNavigator: true);
  if (messenger == null || navigator == null) return;
  final container = ProviderScope.containerOf(context, listen: false);

  final ProbeResult probe;
  try {
    probe = await container.read(clusterPatchBridgeProvider).probe(packageName);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't check $label: $e")),
    );
    return;
  }
  if (!navigator.mounted) return;

  switch (probe.capability) {
    case PatchCapability.red:
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            probe.reason == 'system_app'
                ? "$label is a system app and can't be patched."
                : "$label can't be patched.",
          ),
        ),
      );
    case PatchCapability.green:
      final undo = await showDialog<bool>(
        context: navigator.context,
        builder: (c) => AlertDialog(
          title: Text('$label is patched'),
          content: const Text(
            "It's set up for the cluster. Undo the patch to restore the "
            'original app? (Its data will be reset again.)',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('Undo patch'),
            ),
          ],
        ),
      );
      if (undo == true) {
        if (!navigator.mounted) return;
        final r = await showClusterPatchTerminal<UnpatchOutcome>(
          context: navigator.context,
          mode: PatchTerminalMode.undo,
          packageName: packageName,
          label: label,
          run: () =>
              container.read(clusterPatchBridgeProvider).unpatch(packageName),
          summarize: (o) => switch (o.status) {
            UnpatchStatus.restored => (
              ok: true,
              line: '[✓] RESTORED — original $label reinstalled',
            ),
            UnpatchStatus.removed => (
              ok: true,
              line:
                  '[✓] REMOVED — reinstall $label from the store for the original',
            ),
            UnpatchStatus.failed => (
              ok: false,
              line: '[✗] FAILED: ${o.detail ?? ''}',
            ),
          },
        );
        if (r == null) return;
        container.invalidate(patchedPackagesProvider); // refresh badges
        final msg = switch (r.status) {
          UnpatchStatus.restored => '$label restored to the original.',
          UnpatchStatus.removed =>
            '$label removed. Reinstall it from the store to get the original '
                'back.',
          UnpatchStatus.failed => "Couldn't undo $label: ${r.detail ?? ''}",
        };
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      }
    case PatchCapability.amber:
      await _confirmAndPatch(
        navigator,
        messenger,
        container,
        packageName,
        label,
      );
    case PatchCapability.unknown:
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't check $label — try again.")),
      );
  }
}

Future<void> _confirmAndPatch(
  NavigatorState navigator,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  String packageName,
  String label,
) async {
  final dialogContext = navigator.context;
  // Capture theme up front so we don't touch a BuildContext after an await.
  final errorColor = Theme.of(dialogContext).colorScheme.errorContainer;

  final confirmed = await showDialog<bool>(
    context: dialogContext,
    builder: (c) => AlertDialog(
      title: Text('Patch $label for the cluster?'),
      content: const Text(
        'This reinstalls the app with a modified signature so the car will '
        'let it run on the instrument cluster.\n\n'
        '• The app\'s data will be reset.\n'
        '• Play Store updates stop for it until you reinstall it '
        'normally.\n'
        '• You can undo this later from the app\'s options.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(c).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(c).pop(true),
          child: const Text('Patch'),
        ),
      ],
    ),
  );
  if (confirmed != true || !navigator.mounted) return;

  // Run the patch inside the hacker-terminal progress view: it streams the
  // pipeline steps, prints the real SUCCESS/FAILED line, and returns the
  // outcome when the user closes it.
  final outcome = await showClusterPatchTerminal<PatchOutcome>(
    context: navigator.context,
    mode: PatchTerminalMode.patch,
    packageName: packageName,
    label: label,
    run: () => container.read(clusterPatchBridgeProvider).patch(packageName),
    summarize: (o) => (
      ok: o.ok,
      line: o.ok
          ? '[✓] SUCCESS — $label is cluster-ready'
          : '[✗] FAILED${o.stage == null ? '' : ' at ${o.stage}'}: ${o.detail ?? ''}',
    ),
  );
  if (outcome == null) return;

  if (outcome.ok) {
    container.invalidate(
      patchedPackagesProvider,
    ); // refresh the "Patched" badges
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.status == PatchStatus.alreadyPatched
              ? '$label is already patched — drag it onto the cluster again.'
              : '$label patched — drag it onto the cluster again to cast it.',
        ),
      ),
    );
  } else {
    final where = outcome.stage == null ? '' : ' (${outcome.stage})';
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: errorColor,
        content: Text('Couldn\'t patch $label$where. ${outcome.detail ?? ''}'),
      ),
    );
  }
}
