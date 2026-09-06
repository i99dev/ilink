import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../mini_apps/packaging/pkg_snapshot.dart';
import '../../state/app_drag_controller.dart';
import '../../state/cluster_policy_provider.dart';
import '../../state/installed_apps_provider.dart';
import '../../state/running_apps_provider.dart';
import 'circle_app_icon.dart';
import 'installed_apps_strip.dart' show pkgIconBytesProvider;

/// One chip in a running-apps row — draggable to a display drop card,
/// long-press-context for "stop." Carries `sourceDisplayId` in its
/// payload so the drop handler can tell "user is moving an existing
/// task" from "user is launching an app from the Apps tab" — though
/// in practice both paths converge on `pkg.launch` and the launch
/// resolver picks the right strategy server-side. Source-display is
/// retained primarily for visual feedback (we know to omit the same-
/// display target from the picker).
class RunningAppChip extends ConsumerWidget {
  const RunningAppChip({
    super.key,
    required this.task,
    required this.label,
    this.iconHash,
  });

  final RunningTask task;
  final String label;
  final String? iconHash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iconBytes = (iconHash == null || iconHash!.isEmpty)
        ? null
        : ref
              .watch(
                pkgIconBytesProvider((
                  packageName: task.packageName,
                  iconHash: iconHash!,
                )),
              )
              .value;

    final dragged = DraggedApp(
      packageName: task.packageName,
      label: label,
      iconBytes: iconBytes,
      sourceDisplayId: task.displayId,
    );

    final chip = _ChipChrome(
      label: label,
      iconBytes: iconBytes,
      isForeground: task.isForeground,
      clusterBadge:
          ref
              .watch(clusterFreshLaunchProvider)
              .value
              ?.contains(task.packageName) ??
          false,
    );

    return LongPressDraggable<DraggedApp>(
      data: dragged,
      delay: const Duration(milliseconds: 250),
      hapticFeedbackOnStart: true,
      onDragStarted: () =>
          ref.read(appDragControllerProvider.notifier).start(dragged),
      onDraggableCanceled: (_, _) =>
          ref.read(appDragControllerProvider.notifier).clear(),
      feedback: Material(
        type: MaterialType.transparency,
        child: Opacity(opacity: 0.92, child: chip),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: GestureDetector(
        onTap: () => _showActions(context, ref),
        child: chip,
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    // Capture everything ref-bound BEFORE the first await — the chip
    // (a ConsumerWidget) may rebuild or unmount while the sheet is
    // open or while pkg.stop is in flight, and using `ref` after that
    // throws "Using ref when a widget is about to or has been
    // unmounted is unsafe." The container reference, the bridge
    // instance, and the tick notifier are all safe to hold across
    // async boundaries.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final t = S.of(context);
    // Cluster control was removed from the per-app sheet — there is
    // now ONE touchpad affordance for the entire cluster (the
    // touchpad icon next to the DISPLAYS header). Per-app cluster
    // pads were tied to a specific input-window resolve and didn't
    // help with the common case ("clear a frozen frame from the
    // cluster" / "scroll a map I left there"). The global pad covers
    // both with a single entry-point.
    final action = await showModalBottomSheet<_ChipAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: Text(t.homeRunningAppStop),
              subtitle: Text(t.homeRunningAppForceStopSub(label)),
              onTap: () => Navigator.of(sheetCtx).pop(_ChipAction.stop),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: Text(t.actionCancel),
              onTap: () => Navigator.of(sheetCtx).pop(_ChipAction.cancel),
            ),
          ],
        ),
      ),
    );
    if (action != _ChipAction.stop) return;
    final r = await container
        .read(pkgBridgeProvider)
        .stop(packageName: task.packageName);
    if (r.ok) {
      // Sub-tick refresh so the chip vanishes from the strip
      // immediately, not on the next 2-s polling boundary.
      container.read(runningAppsRefreshTickProvider.notifier).bump();
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          r.ok
              ? 'Stopped $label'
              : 'Could not stop $label: ${r.error ?? r.path}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

enum _ChipAction { stop, cancel }

class _ChipChrome extends StatelessWidget {
  const _ChipChrome({
    required this.label,
    required this.iconBytes,
    required this.isForeground,
    required this.clusterBadge,
  });

  final String label;
  final Uint8List? iconBytes;
  final bool isForeground;

  /// Speedometer badge — this running app is fresh-launched on the
  /// cluster (native `ClusterLaunchPolicy`). Resolved by the parent
  /// (it has the Riverpod `ref`); this widget stays presentational.
  final bool clusterBadge;

  /// Diameter of the circular chip — matches the visual density of
  /// the per-display drop card so a strip of 4-6 chips fits on the
  /// IVI without horizontal scroll. Label-on-tap (Tooltip) handles
  /// the discoverability tradeoff of going icon-only.
  static const double _kSize = 40;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = (label.characters.isEmpty ? '?' : label.characters.first)
        .toUpperCase();
    return Tooltip(
      message: label,
      preferBelow: false,
      child: CircleAppIcon(
        bytes: iconBytes,
        fallback: initial,
        diameter: _kSize,
        clusterBadge: clusterBadge,
        // No drop shadow on chips — the parent display card already
        // has its own frame and the inner shadow muddies the read.
        shadow: false,
        borderColor: isForeground
            ? cs.primary.withValues(alpha: 0.7)
            : cs.outlineVariant.withValues(alpha: 0.5),
        borderWidth: isForeground ? 2 : 1,
      ),
    );
  }
}
