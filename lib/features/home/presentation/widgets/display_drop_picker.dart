import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/_car_domain/display_labels.dart';
import '../../../../sdk/brands/byd/identity/byd_model_detector.dart';
import '../../../cluster_patch/cluster_patch_flow.dart';
import '../../../cluster_touchpad/presentation/cluster_touchpad_sheet.dart';
import '../../../cluster_touchpad/state/cluster_touchpad_controller.dart';
import '../../../mini_apps/runtime/display_native_bridge.dart';
import '../../../mini_apps/runtime/display_snapshot.dart';
import '../../../mini_apps/runtime/display_visibility.dart';
import '../../../mini_apps/runtime/launch_outcome.dart';
import '../../../mini_apps/packaging/pkg_snapshot.dart';
import '../../state/app_drag_controller.dart';
import '../../state/installed_apps_provider.dart';
import '../../state/running_apps_provider.dart';
import 'running_app_chip.dart';

/// One-shot fetch of the active car's displays, gated on model
/// detection so it never resolves against the pre-detection Generic
/// profile (D2 cold-boot fix). `detect()` caches forever, so by the
/// time the user drags it is almost always already resolved — the
/// gate only matters for a drag inside the sub-second boot window.
/// Otherwise same posture as the mini-app actions sheet: hit the
/// bridge once per picker, autoDispose-scoped to the home pane so a
/// cluster hot-plug between drags surfaces on the next gesture
/// without manual invalidation.
///
/// Display identity comes purely from the active `CarProfile` /
/// `DisplayClassifier` (role + `overrideLabel`) via `forPicker()` —
/// the same resolution the slide-panel / app-actions sheet uses.
/// There is no user-calibration layer (removed): every surface that
/// targets a display resolves it identically.
final _picketDisplaysProvider =
    FutureProvider.autoDispose<List<DisplaySnapshot>>((ref) async {
      // Single source of truth: the native `display.list`
      // (`DisplayPlatformPlugin.snapshotList()`) already injects the
      // profile-driven synthetic FSE/passenger surface on Di5.0, so
      // this picker, the mini-app actions sheet, and the SDK all see
      // ONE identical list. Do NOT re-derive it here (that divergence
      // is the audit-D1 anti-pattern).
      //
      // D2: but first ensure detection resolved (and the Kotlin active
      // profile is set) before reading that native list — otherwise
      // the picker can paint Generic labels/dim on a cold-boot drag.
      await ModelDetector.detect();
      final list = await PlatformDisplayNativeBridge().list();
      // Centralised visibility policy — every picker reads the same
      // dim-don't-hide rule (see `display_visibility.dart`). Shadows
      // appear at the end of the list with a dim styling so users can
      // still target them.
      return list.forPicker();
    });

/// Per-display drop state — IDLE while waiting for a drop, LOADING
/// during the in-flight pkg.launch / pkg.launch_cluster, OK / ERROR
/// for ~1.2 s after the result arrives so the user sees confirmation
/// before the picker fades out. The drop ends the drag (controller
/// clears) which fades the picker; the result flash plays inside
/// that fade window.
enum _DropState { idle, loading, ok, error }

/// Per-display widget that lives in the home left pane. Three roles
/// merged into one surface:
///
///   * **Drop target** — when the user is long-press-dragging an app
///     from the Apps tab in the right pane (or a chip from another
///     card), each card highlights as a [DragTarget]. Drop fires
///     `pkg.launch` (or `pkg.launch_cluster` for cluster targets);
///     the launch resolver server-side picks Resume / Migrate /
///     FreshLaunch so we never spawn a duplicate task.
///   * **Running-apps view** — each card carries an inline
///     [RunningAppChip] strip showing the tasks currently on that
///     display. Each chip is itself draggable to another card.
///
/// Visual posture mirrors the pkg-launcher mini-app's target cards
/// so users perceive one drop-picker language across both surfaces.
class DisplayDropPicker extends ConsumerStatefulWidget {
  const DisplayDropPicker({super.key});

  /// Android `Display.DEFAULT_DISPLAY` constant — the IVI card uses
  /// this for its `displayId` slot so chip-source-display matching
  /// works the same way it does for secondary displays. Mirrors the
  /// `DEFAULT_DISPLAY` Kotlin literal; not imported from a Flutter
  /// constant because Dart-side has no analogue.
  static const int _defaultDisplayId = 0;

  @override
  ConsumerState<DisplayDropPicker> createState() => _DisplayDropPickerState();
}

class _DisplayDropPickerState extends ConsumerState<DisplayDropPicker> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dragged = ref.watch(appDragControllerProvider);
    final displaysAsync = ref.watch(_picketDisplaysProvider);
    final runningAsync = ref.watch(runningAppsProvider);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dragged != null ? 'DROP TO LAUNCH' : 'DISPLAYS',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.primary,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dragged?.label ??
                            'Long-press an app or chip to move it between screens',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Global cluster touchpad — ONE entry point per car,
                // not per-app. Shown only when the active CarProfile
                // exposes a reachable cluster (resolved by the same
                // `forPicker(excludeDefault)` pipeline the cards use,
                // so the icon can never disagree with the surfaces
                // the picker renders). Tap opens a sheet sized to the
                // cluster's actual aspect ratio plus a "Clear cluster"
                // action that force-stops + repaints the cluster on
                // a hung frame — the operator-attested 2026-05-20
                // failure mode where a map / image stays drawn after
                // its app moves back to the IVI.
                const _ClusterTouchpadHeaderIcon(),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: displaysAsync.when(
                loading: () => const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
                error: (_, _) => Center(
                  child: Text(
                    'Could not list displays',
                    style: TextStyle(color: cs.error, fontSize: 13),
                  ),
                ),
                data: (displays) {
                  // `.value` instead of `maybeWhen(data:, orElse:)`
                  // so chips don't flicker to empty during the
                  // 2-s polling refresh — see the matching
                  // comment in assistant_panel.dart.
                  final running =
                      runningAsync.value ?? const <int, List<RunningTask>>{};
                  return _Cards(displays: displays, running: running);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cards extends ConsumerWidget {
  const _Cards({required this.displays, required this.running});
  final List<DisplaySnapshot> displays;
  final Map<int, List<RunningTask>> running;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Single source of truth, identical to the slide-panel /
    // app-actions sheet: `forPicker()` order (live first, dimmed
    // shadows at the tail, IVI included) and membership purely from
    // the active CarProfile / DisplayClassifier — show the IVI, and
    // any display the profile gives a real role. No user-calibration
    // overlay (removed): every surface resolves displays the same way.
    final visible = displays.forPicker().where((d) {
      if (d.isDefault) return true;
      return d.role.isNotEmpty && d.role != 'unknown';
    }).toList();

    // Hide the whole picker on a model with no selectable secondary
    // surface — same centralised rule the sheets use.
    final hasSecondaryTarget = displays
        .forPicker(excludeDefault: true)
        .isNotEmpty;
    if (visible.isEmpty || !hasSecondaryTarget) {
      return const _NoSecondaryDisplays();
    }

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        for (final d in visible) ...[
          if (d != visible.first) const SizedBox(height: 10),
          if (d.isDefault)
            _IviCard(tasks: running[d.id] ?? const <RunningTask>[])
          else
            _SecondaryCard(
              display: d,
              tasks: running[d.id] ?? const <RunningTask>[],
            ),
        ],
      ],
    );
  }
}

/// Shown when the active CarProfile exposes no selectable secondary
/// surface (single-display trim, or all secondaries filtered).
class _NoSecondaryDisplays extends StatelessWidget {
  const _NoSecondaryDisplays();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.desktop_access_disabled_outlined,
                size: 32,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(
                'No secondary displays',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'This car exposes only the head unit — there is no '
                'passenger or cluster screen to move apps to.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IviCard extends StatefulWidget {
  const _IviCard({required this.tasks});
  final List<RunningTask> tasks;

  @override
  State<_IviCard> createState() => _IviCardState();
}

class _IviCardState extends State<_IviCard> {
  _DropState _state = _DropState.idle;
  String? _err;
  bool _wmsTransient = false;
  DraggedApp? _lastAttempt;

  @override
  Widget build(BuildContext context) {
    return _DropCard(
      title: 'Head Unit',
      subtitle: 'Open here on the dash',
      icon: Icons.dashboard_outlined,
      state: _state,
      errorText: _err,
      displayId: DisplayDropPicker._defaultDisplayId,
      tasks: widget.tasks,
      // When the card is in WMS-transient error state, tapping it
      // re-fires the same launch — gives the user a no-friction
      // "try again" without re-dragging.
      onTap: _wmsTransient && _lastAttempt != null
          ? () => _retryLast(context)
          : null,
      onAccept: (consumer, dragged) async {
        // Capture container BEFORE await — `consumer` (a WidgetRef)
        // becomes unsafe if the inner Consumer in [_DropCard]
        // rebuilds while pkg.launch is in flight. The container is
        // process-stable, safe across async boundaries.
        final container = ProviderScope.containerOf(context, listen: false);
        _lastAttempt = dragged;
        await _runLaunch(container, dragged);
      },
    );
  }

  Future<void> _retryLast(BuildContext context) async {
    final dragged = _lastAttempt;
    if (dragged == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    await _runLaunch(container, dragged);
  }

  Future<void> _runLaunch(
    ProviderContainer container,
    DraggedApp dragged,
  ) async {
    setState(() => _state = _DropState.loading);
    try {
      final bridge = container.read(pkgBridgeProvider);
      // Source = running chip on a non-default display → the task
      // already exists, we want to bring it back to the IVI (default
      // display). Use `pkg.launch` without displayId — the launch
      // resolver picks Migrate when the package is already running
      // elsewhere, so this reparents the existing task instead of
      // spawning a fresh one.
      final r = await bridge.launch(packageName: dragged.packageName);
      if (!mounted) return;
      setState(() {
        _state = r.ok ? _DropState.ok : _DropState.error;
        _wmsTransient = !r.ok && r.wmsTransient;
        _err = r.ok
            ? null
            : (r.wmsTransient
                  ? 'WMS hiccup — tap card to retry'
                  : r.error?.toString());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DropState.error;
        _wmsTransient = false;
        _err = e.toString();
      });
    }
    await _flashAndClear(container);
  }

  Future<void> _flashAndClear(ProviderContainer container) async {
    // Sub-tick refresh so the chip strip moves to the new display
    // immediately, not on the next 2-s polling boundary.
    container.read(runningAppsRefreshTickProvider.notifier).bump();
    // Linger longer on WMS-transient so users see the retry hint;
    // 900 ms is invisible-fast on success / hard-fail.
    final lingerMs = _wmsTransient ? 3000 : 900;
    await Future<void>.delayed(Duration(milliseconds: lingerMs));
    // Clear the drag controller FIRST and unconditionally — it's
    // process-stable via `container`, doesn't need this widget
    // mounted, and is what un-force-shows the picker. A cluster
    // hot-plug / forPicker() reorder can unmount this card during
    // the linger; since the drop was accepted, LongPressDraggable's
    // onDraggableCanceled never fires either, so a mounted-gated
    // clear would jam the picker open with no drag in progress.
    container.read(appDragControllerProvider.notifier).clear();
    // The local idle reset is the only mounted-gated part — a dead
    // card needs no setState.
    if (!mounted) return;
    setState(() {
      _state = _DropState.idle;
      _err = null;
      _wmsTransient = false;
    });
  }
}

class _SecondaryCard extends StatefulWidget {
  const _SecondaryCard({required this.display, required this.tasks});
  final DisplaySnapshot display;
  final List<RunningTask> tasks;

  @override
  State<_SecondaryCard> createState() => _SecondaryCardState();
}

class _SecondaryCardState extends State<_SecondaryCard> {
  _DropState _state = _DropState.idle;
  String? _err;
  bool _wmsTransient = false;
  DraggedApp? _lastAttempt;

  @override
  Widget build(BuildContext context) {
    final d = widget.display;
    final isCluster = d.role == 'cluster' || d.isCluster;
    final title = _humanLabel(d);
    final subtitle = _subtitleFor(d);

    return _DropCard(
      title: title,
      subtitle: subtitle,
      icon: isCluster
          ? Icons.dashboard_customize_outlined
          : Icons.airplay_outlined,
      // Two reasons to dim: cluster the profile says isn't reachable
      // on this trim, OR a duplicate/shadow surface the profile
      // flagged (see `display_visibility.dart`). Both keep the card
      // as a live drop target — firmware revs vary, and the user
      // may know better than the profile.
      // Projection-cast displays (L7 "Driver Cluster") are fully
      // reachable via our own VirtualDisplay, so don't dim them on the
      // !clusterAvailable basis — only a real shadow/hidden reason dims.
      dimmed:
          (isCluster && !d.clusterAvailable && d.castMode != 'project') ||
          d.isDimmed,
      state: _state,
      errorText: _err,
      displayId: d.id,
      tasks: widget.tasks,
      // Tap-to-retry only while the card is showing a WMS-transient
      // failure; the rest of the time the card is non-tappable.
      onTap: _wmsTransient && _lastAttempt != null
          ? () => _retryLast(context, isCluster, d.id, d.role)
          : null,
      // Chip-independent escape: the running-chip on a secondary
      // card can be absent (poll lag / host filter / a bouncy
      // foreign app mid-relaunch on the XDJA cluster), so a
      // drag-off is unreliable. This button resolves whatever the
      // host says is on THIS display (`pkg.topOnDisplay`) and sends
      // it to the Head Unit — `Context.startActivity`, the one path
      // that's deterministic on every trim / both DiLink gens.
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        iconSize: 20,
        tooltip: 'Send to Head Unit',
        icon: const Icon(Icons.exit_to_app),
        onPressed: _state == _DropState.loading
            ? null
            : () {
                final container = ProviderScope.containerOf(
                  context,
                  listen: false,
                );
                _sendToHeadUnit(container);
              },
      ),
      onAccept: (consumer, dragged) async {
        // Capture container BEFORE await — `consumer` (a WidgetRef)
        // becomes unsafe if the inner Consumer in [_DropCard]
        // rebuilds while pkg.launch is in flight. The container is
        // process-stable, safe across async boundaries.
        final container = ProviderScope.containerOf(context, listen: false);
        _lastAttempt = dragged;
        // Driver Cluster used to be PiP-gated for safety, but the BYD
        // ROM's PiP implementation swallowed the action broadcasts
        // and a Flutter dialog stand-in proved more friction than
        // value. Driver drops now launch directly like every other
        // display — same _runLaunch path, same WMS retry.
        await _runLaunch(container, dragged, isCluster, d.id, d.role);
      },
    );
  }

  Future<void> _retryLast(
    BuildContext context,
    bool isCluster,
    int displayId,
    String role,
  ) async {
    final dragged = _lastAttempt;
    if (dragged == null) return;
    final container = ProviderScope.containerOf(context, listen: false);
    await _runLaunch(container, dragged, isCluster, displayId, role);
  }

  Future<void> _runLaunch(
    ProviderContainer container,
    DraggedApp dragged,
    bool isCluster,
    int displayId,
    String role,
  ) async {
    setState(() => _state = _DropState.loading);
    try {
      final bridge = container.read(pkgBridgeProvider);
      // Cluster targets always go through launchCluster — the
      // permission tier + role check live there. For non-cluster
      // (passenger / aux), `launch` is the single entry: its
      // resolver picks Resume / Migrate / FreshLaunch internally,
      // so we don't need a separate move() call when dragging from
      // a running chip. One central decision point.
      // L7 (XDJA fission) cluster: a foreign app cannot be moved/launched
      // directly onto the OWN_CONTENT_ONLY projection display without
      // hanging the head unit (group-0 reshuffle + FissionGenerayService
      // latch). The profile flags it with castMode='project' so we route
      // through projectToCluster — cast via our own VirtualDisplay (the
      // the reference mechanism). Every other display keeps castMode='launch'
      // → the unchanged launchCluster / launch path.
      final useProjection = widget.display.castMode == 'project';
      final r = useProjection
          ? await bridge.projectToCluster(
              packageName: dragged.packageName,
              displayId: displayId,
            )
          : isCluster
          ? await bridge.launchCluster(
              packageName: dragged.packageName,
              displayId: displayId,
            )
          : await bridge.launch(
              packageName: dragged.packageName,
              displayId: displayId,
              targetRole: role,
            );
      if (!mounted) return;
      setState(() {
        _state = r.ok ? _DropState.ok : _DropState.error;
        _wmsTransient = !r.ok && r.wmsTransient;
        _err = r.wmsTransient
            ? 'WMS hiccup — tap card to retry'
            : _resultMessage(r);
      });
      // Native-first → reveal-on-failure: a hard (non-transient) cluster
      // cast failure is the trigger to offer the patch remediation. The
      // offer probes eligibility and shows an app-level SnackBar, so it
      // survives this card auto-clearing. See features/cluster_patch.
      if (isCluster && !r.ok && !r.wmsTransient) {
        unawaited(
          offerClusterPatch(
            context: context,
            container: container,
            packageName: dragged.packageName,
            label: dragged.label,
          ),
        );
      }
      // A projection cast just changed what's on the cluster VD — re-
      // resolve the touchpad target so its icon appears (input now has a
      // VirtualDisplay to forward to).
      if (useProjection && r.ok) {
        container.invalidate(clusterTouchpadTargetProvider);
      }
      // Auto-PiP-on-secondary warning: native side detects when the
      // moved app calls `enterPictureInPictureMode` on launch (Sygic
      // Maps, BYD media player). Move succeeded — app is on the
      // target display — but it'll render as a small floating window
      // instead of full-screen, because of the app's own settings.
      // Surface as a snackbar so the operator knows to pick a
      // different app for a full-screen experience.
      if (r.ok && r.path.contains('auto-pip')) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              '${dragged.label} will show as a small window on the cluster '
              '(the app entered picture-in-picture mode). Try a different '
              'app for full-screen.',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DropState.error;
        _wmsTransient = false;
        _err = e.toString();
      });
    }
    await _flashAndClear(container);
  }

  Future<void> _flashAndClear(ProviderContainer container) async {
    // Bump immediately so the chip strip reflects the move on the
    // next frame, not the next 2-s polling boundary.
    container.read(runningAppsRefreshTickProvider.notifier).bump();
    final lingerMs = _wmsTransient ? 3000 : 900;
    await Future<void>.delayed(Duration(milliseconds: lingerMs));
    // Clear the drag controller FIRST and unconditionally — it's
    // process-stable via `container`, doesn't need this widget
    // mounted, and is what un-force-shows the picker. A cluster
    // hot-plug / forPicker() reorder can unmount this card during
    // the linger; since the drop was accepted, LongPressDraggable's
    // onDraggableCanceled never fires either, so a mounted-gated
    // clear would jam the picker open with no drag in progress.
    container.read(appDragControllerProvider.notifier).clear();
    // The local idle reset is the only mounted-gated part — a dead
    // card needs no setState.
    if (!mounted) return;
    setState(() {
      _state = _DropState.idle;
      _err = null;
      _wmsTransient = false;
    });
  }

  /// Resolve whatever the host says is on THIS display (authoritative
  /// `am stack list`, not the polled chip cache) and relaunch it on
  /// the Head Unit. `bridge.launch` with no displayId → IVI /
  /// `Context.startActivity` — the only relocation that's
  /// deterministic on every trim and both DiLink generations (no
  /// XDJA move-task, no DiShare re-cast). Fixes "stuck on the
  /// cluster, can't get it back".
  Future<void> _sendToHeadUnit(ProviderContainer container) async {
    setState(() => _state = _DropState.loading);
    try {
      final bridge = container.read(pkgBridgeProvider);
      // Projection cluster (L7): the cast app runs on our VirtualDisplay,
      // not on this card's Android display, so topOnDisplay can't see it.
      // Stop the projection (releases the VD + force-stops the cast app)
      // and relaunch that app on the IVI — the real "return to Head Unit".
      if (widget.display.castMode == 'project') {
        final cast = await bridge.stopClusterProjection();
        container.invalidate(clusterTouchpadTargetProvider);
        final r = cast == null
            ? const LaunchResult(ok: true, path: 'cluster_projection_stopped')
            : await bridge.launch(packageName: cast);
        if (!mounted) return;
        setState(() {
          _state = r.ok ? _DropState.ok : _DropState.error;
          _wmsTransient = !r.ok && r.wmsTransient;
          _err = r.ok ? null : _resultMessage(r);
        });
        await _flashAndClear(container);
        return;
      }
      final pkg = await bridge.topOnDisplay(widget.display.id);
      if (pkg == null) {
        if (!mounted) return;
        setState(() {
          _state = _DropState.error;
          _wmsTransient = false;
          _err = 'Nothing on this screen';
        });
      } else {
        final r = await bridge.launch(packageName: pkg);
        if (!mounted) return;
        setState(() {
          _state = r.ok ? _DropState.ok : _DropState.error;
          _wmsTransient = !r.ok && r.wmsTransient;
          _err = r.ok ? null : _resultMessage(r);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _DropState.error;
        _wmsTransient = false;
        _err = e.toString();
      });
    }
    await _flashAndClear(container);
  }

  /// Profile/classifier-derived label — same resolution the
  /// slide-panel / app-actions sheet uses (`overrideLabel` → role →
  /// cluster catch-all). No user-calibration override (removed).
  String _humanLabel(DisplaySnapshot d) => displayHumanLabel(d);

  String _subtitleFor(DisplaySnapshot d) {
    final isCluster = d.role == 'cluster' || d.isCluster;
    final size = '${d.width}×${d.height}';
    final base = d.castMode == 'project'
        // Reachable via our own VirtualDisplay (the projection path) —
        // NOT "unsupported"; the cluster casts fine, just by a different
        // mechanism than launch/move.
        ? '$size · drop an app to cast it here'
        : !isCluster
        ? size
        : !d.clusterAvailable
        ? '$size · cluster not supported on this trim'
        : '$size · cluster — pixels may be vendor-gated';
    // VehicleProfile-supplied dim reason (e.g. "mirrors Display 5"
    // on L8) lands at the tail so the user sees the cluster note
    // first when both apply.
    final dim = d.dimSubtitle;
    return dim == null ? base : '$base · $dim';
  }

  /// Terse in-card text, derived from the shared [classifyLaunchKind]
  /// so the success/failure boundary is identical to the slide-panel
  /// sheet's snackbar (the rendering differs — terse here, a full
  /// sentence there — but the *decision* is single-sourced). Clean
  /// success stays silent (the green check is the confirmation).
  String? _resultMessage(LaunchResult r) {
    final kind = classifyLaunchKind(
      ok: r.ok,
      path: r.path,
      error: r.error,
      wmsTransient: r.wmsTransient,
    );
    switch (kind) {
      case LaunchOutcomeKind.success:
        return null;
      case LaunchOutcomeKind.recovered:
        return 'Recovered after bounce';
      case LaunchOutcomeKind.warning:
        // The caller handles wmsTransient via its own dedicated
        // branch before calling this; kept for parity if it ever
        // reaches here.
        return 'WMS hiccup — tap card to retry';
      case LaunchOutcomeKind.failure:
        return r.error?.toString() ??
            (r.path.isEmpty ? 'launch failed' : r.path);
    }
  }
}

/// Visual shell of a drop card — handles the DragTarget plumbing,
/// hover highlight, and the per-state overlay (spinner / check /
/// error). The owning state widget plugs in the actual launch logic
/// via [onAccept]. Embedded chip strip shows tasks currently on
/// this display; chip-to-card drops on the same display are
/// rejected so a chip can't be dropped onto its own home (no-op
/// move would be silly UX).
class _DropCard extends StatelessWidget {
  const _DropCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.state,
    required this.onAccept,
    required this.displayId,
    required this.tasks,
    this.dimmed = false,
    this.errorText,
    this.onTap,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final _DropState state;
  final String? errorText;
  final bool dimmed;
  final int displayId;
  final List<RunningTask> tasks;

  /// Optional action affordance rendered in the card header (the
  /// secondary cards' "→ Head Unit" escape). Null on the IVI card.
  final Widget? trailing;

  /// The owning card hands us a `WidgetRef` (so we don't have to
  /// thread one through every state-widget) plus the dragged app.
  final Future<void> Function(WidgetRef ref, DraggedApp dragged) onAccept;

  /// Optional tap handler — wired only by the WMS-transient retry
  /// path so that during the linger window a tap on the card re-
  /// fires the failed launch. Null at all other times so the card
  /// is non-interactive when not in retry state.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final inner = DragTarget<DraggedApp>(
          onWillAcceptWithDetails: (details) {
            if (state == _DropState.loading) return false;
            // Reject drops where the chip's source display equals
            // ours — the chip is already here, no move to do.
            return details.data.sourceDisplayId != displayId;
          },
          onAcceptWithDetails: (details) => onAccept(ref, details.data),
          builder: (context, candidate, _) {
            final hovering = candidate.isNotEmpty;
            return _CardChrome(
              title: title,
              subtitle: subtitle,
              icon: icon,
              state: state,
              hovering: hovering,
              dimmed: dimmed,
              errorText: errorText,
              tasks: tasks,
              trailing: trailing,
              installed: ref.watch(installedAppsProvider).value,
            );
          },
        );
        // GestureDetector wraps the whole card so the tap-to-retry
        // affordance lights up the entire surface, not just the
        // chrome inside the DragTarget. When [onTap] is null the
        // gesture passes through.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: inner,
        );
      },
    );
  }
}

class _CardChrome extends StatelessWidget {
  const _CardChrome({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.state,
    required this.hovering,
    required this.dimmed,
    required this.errorText,
    required this.tasks,
    required this.installed,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final _DropState state;
  final bool hovering;
  final bool dimmed;
  final String? errorText;
  final List<RunningTask> tasks;
  final List<PackageSnapshot>? installed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = switch (state) {
      _DropState.ok => Colors.green.withValues(alpha: 0.7),
      _DropState.error => cs.error,
      _ => hovering ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5),
    };
    final bg = hovering
        ? cs.primary.withValues(alpha: 0.12)
        : cs.surfaceContainerHigh.withValues(alpha: 0.5);

    return Opacity(
      opacity: dimmed ? 0.7 : 1.0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: hovering ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 26, color: cs.onSurface),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state == _DropState.error && errorText != null
                            ? errorText!
                            : subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: state == _DropState.error
                              ? cs.error
                              : cs.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                const SizedBox(width: 8),
                _StateGlyph(state: state),
              ],
            ),
            if (tasks.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in tasks)
                    RunningAppChip(
                      task: t,
                      label: _labelFor(t.packageName, installed),
                      iconHash: _iconHashFor(t.packageName, installed),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _labelFor(String pkg, List<PackageSnapshot>? installed) {
    if (installed == null) return pkg;
    for (final app in installed) {
      if (app.packageName == pkg) {
        return app.label.isEmpty ? pkg : app.label;
      }
    }
    return pkg;
  }

  static String? _iconHashFor(String pkg, List<PackageSnapshot>? installed) {
    if (installed == null) return null;
    for (final app in installed) {
      if (app.packageName == pkg) return app.iconHash;
    }
    return null;
  }
}

/// Header affordance for the global cluster touchpad. Watches the
/// resolution provider so the icon stays in sync with the active
/// `CarProfile`'s cluster surface:
///   * `loading` / `error` ⇒ no icon (no flicker on cold boot, no
///     dead button on a flaky bridge).
///   * `data: null` ⇒ no icon (single-display trim — there is
///     nothing to control).
///   * `data: target` ⇒ icon rendered, tap opens the sheet.
///
/// One-time bridge call on first build; the provider caches inside
/// the home pane's scope.
class _ClusterTouchpadHeaderIcon extends ConsumerWidget {
  const _ClusterTouchpadHeaderIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(clusterTouchpadTargetProvider);
    return target.maybeWhen(
      data: (t) {
        if (t == null) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'Open ${t.label} touchpad',
          icon: const Icon(Icons.touch_app),
          visualDensity: VisualDensity.compact,
          onPressed: () => showClusterTouchpadSheet(context),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.state});
  final _DropState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 24,
      height: 24,
      child: switch (state) {
        _DropState.idle => Icon(
          Icons.south_outlined,
          size: 20,
          color: cs.onSurfaceVariant.withValues(alpha: 0.6),
        ),
        _DropState.loading => const CircularProgressIndicator(strokeWidth: 2.5),
        _DropState.ok => const Icon(
          Icons.check_circle_rounded,
          size: 22,
          color: Colors.green,
        ),
        _DropState.error => Icon(
          Icons.error_outline,
          size: 22,
          color: cs.error,
        ),
      },
    );
  }
}
