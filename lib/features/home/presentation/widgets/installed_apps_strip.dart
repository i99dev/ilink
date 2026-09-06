import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../app_actions/index.dart';
import '../../../mini_apps/packaging/pkg_snapshot.dart';
import '../../state/app_drag_controller.dart';
import '../../state/cluster_policy_provider.dart';
import '../../state/displays_picker_active_provider.dart';
import '../../state/installed_apps_provider.dart';
import 'circle_app_icon.dart';

/// Process-static cache of decoded launcher PNGs, keyed by the host's
/// `iconHash` (`pkg@versionCode`). Populated lazily by [_PkgIcon] on
/// first paint of each tile and never evicted — same posture as the
/// SDK-side iconCache in the pkg-launcher mini-app: 100+ launchable
/// apps × ~6 KB each = under a megabyte, well below the dashboard's
/// budget. Version-bumped iconHash naturally invalidates a stale
/// entry on the next pkg.list refresh.
final _iconBytesCache = <String, Uint8List?>{};

/// Per-iconHash future provider — guarantees one in-flight `pkg.icon`
/// per package even with the strip rebuilding repeatedly while the
/// home pane is re-laid-out. `keepAlive` because dispose-on-unmount
/// would re-fetch every time the user swipes between Apps and
/// Miniapps tabs, defeating the host-side LRU.
///
/// Exported (top-level, no leading underscore) so the running-apps
/// chip strip can reuse the same cache — one icon fetch serves both
/// the Apps tile and any chip representing the same package, instead
/// of two parallel caches that go stale independently.
final pkgIconBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String packageName, String iconHash})>((
      ref,
      args,
    ) async {
      ref.keepAlive();
      final cached = _iconBytesCache[args.iconHash];
      if (cached != null) return cached;
      final res = await ref
          .read(pkgBridgeProvider)
          .icon(packageName: args.packageName);
      if (!res.ok || res.pngBase64 == null) {
        _iconBytesCache[args.iconHash] = null;
        return null;
      }
      final bytes = base64Decode(res.pngBase64!);
      _iconBytesCache[args.iconHash] = bytes;
      return bytes;
    });

/// Horizontal strip of native Android packages installed on the IVI.
///
/// Sourced from [installedAppsProvider]; tap launches via the
/// [pkgBridgeProvider] on the default display. Mirrors the visual
/// frame and tile sizing of [FavoriteMiniAppsStrip] so the two
/// strips co-exist inside a tabbed panel without layout drift.
class InstalledAppsStrip extends ConsumerWidget {
  const InstalledAppsStrip({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final apps = ref.watch(installedAppsProvider);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTitle) ...[
              Text(
                t.installedAppsTitle,
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: apps.when(
                loading: () => const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
                error: (_, _) => _Hint(text: t.installedAppsLaunchFailed),
                data: (list) => list.isEmpty
                    ? _Hint(text: t.installedAppsEmptyHint)
                    : _Strip(apps: list),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline, fontSize: 13, height: 1.4),
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.apps});
  final List<PackageSnapshot> apps;

  // Mirror FavoriteMiniAppsStrip's App-Store-style vertical grid: max
  // cross-axis extent auto-fits columns to whatever width the right
  // pane gives us, and an asymmetric main/cross spacing reads cleaner
  // on a card grid than equal whitespace.
  static const _kTileMaxExtent = 120.0;
  static const _kCrossGap = 12.0;
  static const _kMainGap = 18.0;
  static const _kTileAspect = 0.92;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _kTileMaxExtent,
        crossAxisSpacing: _kCrossGap,
        mainAxisSpacing: _kMainGap,
        childAspectRatio: _kTileAspect,
      ),
      itemCount: apps.length,
      itemBuilder: (ctx, i) => _InstalledTile(app: apps[i]),
    );
  }
}

class _InstalledTile extends ConsumerWidget {
  const _InstalledTile({required this.app});
  final PackageSnapshot app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final label = app.label.isEmpty ? app.packageName : app.label;
    // Resolved icon bytes (null while the FutureProvider is in flight
    // or when the host couldn't render a drawable). We pass these
    // through to the LongPressDraggable feedback so the floating
    // widget under the finger shows the real icon when we have it,
    // not just the tinted-initial fallback.
    final hash = app.iconHash;
    final Uint8List? iconBytes = (hash == null || hash.isEmpty)
        ? null
        : ref
              .watch(
                pkgIconBytesProvider((
                  packageName: app.packageName,
                  iconHash: hash,
                )),
              )
              .value;

    final isBeingDragged = ref.watch(
      appDragControllerProvider.select(
        (d) => d?.packageName == app.packageName,
      ),
    );

    final tile = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 72 px App-Store-style icon with a soft drop-shadow —
          // matches the mini-apps favourites strip in the sibling
          // tab AND the pkg-launcher mini-app's full grid, so the
          // user perceives one coherent app-tile language across
          // the home and launcher surfaces. Circular shape matches
          // the running-app chips inside the DISPLAYS picker — one
          // visual vocabulary, one widget ([CircleAppIcon]).
          CircleAppIcon(
            diameter: 72,
            // Speedometer badge when this app is fresh-launched on
            // the cluster (native ClusterLaunchPolicy). One batched
            // classify backs the whole grid — see
            // [clusterFreshLaunchProvider].
            clusterBadge:
                ref
                    .watch(clusterFreshLaunchProvider)
                    .value
                    ?.contains(app.packageName) ??
                false,
            // The Apps tile uses _PkgIcon (a stateful widget that
            // resolves icon bytes lazily and falls back to a tinted
            // initial). Pass it as `child` rather than collapsing
            // into bytes so we keep the existing per-package
            // tinted-fallback behaviour during icon-fetch latency.
            child: _PkgIcon(app: app),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    // Gesture model is mode-driven, not always-on:
    //   * Show Displays ACTIVE — long-press starts a LongPressDraggable
    //     that drops onto the display picker on the left pane (the
    //     original "drag to launch on cluster / passenger" flow).
    //   * Show Displays inactive — long-press opens the unified actions
    //     sheet (Open-on / Enable / Disable / Uninstall / Move /
    //     Force-stop / Clear / Whitelist).
    // Tap-launch is the same in both modes.
    final pickerActive = ref.watch(displaysPickerActiveProvider);
    if (pickerActive) {
      return LongPressDraggable<DraggedApp>(
        data: DraggedApp(
          packageName: app.packageName,
          label: label,
          iconBytes: iconBytes,
        ),
        // ~250 ms is Material's standard long-press; matches the
        // mini-app actions sheet on the sibling tab so users get one
        // gesture vocabulary across both grids.
        delay: const Duration(milliseconds: 250),
        hapticFeedbackOnStart: true,
        onDragStarted: () => ref
            .read(appDragControllerProvider.notifier)
            .start(
              DraggedApp(
                packageName: app.packageName,
                label: label,
                iconBytes: iconBytes,
              ),
            ),
        // Only the cancelled (missed-target) path clears the controller
        // here — when the drop IS accepted, the receiving DragTarget
        // owns the lifecycle: it keeps the picker visible during the
        // in-flight pkg.launch and clears the controller after the
        // result flash.
        onDraggableCanceled: (_, _) =>
            ref.read(appDragControllerProvider.notifier).clear(),
        feedback: _DragFeedback(label: label, iconBytes: iconBytes),
        childWhenDragging: Opacity(opacity: 0.35, child: tile),
        child: Opacity(
          opacity: isBeingDragged ? 0.35 : 1.0,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _launch(context, ref),
            child: tile,
          ),
        ),
      );
    }
    return Opacity(
      opacity: isBeingDragged ? 0.35 : 1.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _launch(context, ref),
        onLongPress: () => _openActionsSheet(context, ref, label, iconBytes),
        child: tile,
      ),
    );
  }

  Future<void> _openActionsSheet(
    BuildContext context,
    WidgetRef ref,
    String label,
    Uint8List? iconBytes,
  ) async {
    await showAppActionsSheet(
      context: context,
      target: NativeAppTarget(
        packageName: app.packageName,
        label: label,
        iconBytes: iconBytes,
      ),
    );
    // An action in the sheet (uninstall / disable) can change what's
    // installed. The uninstall is a silent `pm uninstall` (no system dialog,
    // so no app-resume fires), and this grid stays mounted — invalidate so a
    // removed app drops out immediately instead of lingering until reopen.
    ref.invalidate(installedAppsProvider);
  }

  Future<void> _launch(BuildContext context, WidgetRef ref) async {
    final t = S.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await ref
          .read(pkgBridgeProvider)
          .launch(packageName: app.packageName);
      if (result.ok) return;
      // BYD WMS transient — surface a Retry action. The user-driven
      // retry usually succeeds because the WMS state has settled by
      // the time their finger lands on the SnackBar action.
      if (result.wmsTransient) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(t.installedAppsLaunchFailed),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _launch(context, ref),
            ),
          ),
        );
        return;
      }
      messenger?.showSnackBar(
        SnackBar(content: Text(t.installedAppsLaunchFailed)),
      );
    } catch (e, st) {
      // Unknown error — log it (so triage has the stack) but keep
      // the user-visible message identical to the generic failure
      // branch. No Retry: we don't know whether the throw is
      // transient, so offering retry would just re-throw.
      developer.log(
        'installed_apps_strip launch threw',
        name: 'InstalledAppsStrip',
        error: e,
        stackTrace: st,
      );
      messenger?.showSnackBar(
        SnackBar(content: Text(t.installedAppsLaunchFailed)),
      );
    }
  }
}

/// Floating chip rendered under the finger during a long-press
/// drag. A scaled-up icon + label pill, slightly translucent so the
/// user can still see the drop target underneath. Only rendered
/// while the displays-picker is active and the user has long-pressed
/// an app; otherwise the long-press routes to the actions sheet.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label, required this.iconBytes});

  final String label;
  final Uint8List? iconBytes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Decode launcher PNGs at the painted size × dpr — Android ships
    // 192–512 px source bitmaps, so without `cacheWidth`/`cacheHeight`
    // the engine uploads a multi-megabyte texture per drag-feedback
    // overlay. 84 px × dpr matches the actual paint footprint.
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final cacheSize = (84 * dpr).round();
    return Material(
      type: MaterialType.transparency,
      child: Opacity(
        opacity: 0.92,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: iconBytes != null
                    ? Image.memory(
                        iconBytes!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        cacheWidth: cacheSize,
                        cacheHeight: cacheSize,
                      )
                    : Center(
                        child: Text(
                          (label.characters.isEmpty
                                  ? '?'
                                  : label.characters.first)
                              .toUpperCase(),
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Real launcher icon with a tinted first-letter fallback. The
/// fallback paints immediately so the strip has no holes during the
/// async fetch, then [Image.memory] swaps in once the bridge resolves.
/// On older hosts (no `pkg.icon` handler) or apps without a loadable
/// drawable, the fallback stays — visually identical to the legacy
/// "color-blob initial" tiles.
class _PkgIcon extends ConsumerWidget {
  const _PkgIcon({required this.app});
  final PackageSnapshot app;

  static const _palette = <int>[0, 1, 2];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final label = app.label.isEmpty ? app.packageName : app.label;
    final initial = label.characters.isEmpty
        ? '?'
        : label.characters.first.toUpperCase();
    // Hash-stable tint per package — gives a 100-app strip enough
    // colour variety that fallback tiles don't all look identical
    // while we wait on the icon fetch.
    final slot = _palette[app.packageName.hashCode.abs() % _palette.length];
    final bg = switch (slot) {
      0 => cs.primaryContainer,
      1 => cs.secondaryContainer,
      _ => cs.tertiaryContainer,
    };
    final fg = switch (slot) {
      0 => cs.onPrimaryContainer,
      1 => cs.onSecondaryContainer,
      _ => cs.onTertiaryContainer,
    };
    final fallback = DecoratedBox(
      decoration: BoxDecoration(color: bg),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
    final hash = app.iconHash;
    if (hash == null || hash.isEmpty) return fallback;
    final asyncBytes = ref.watch(
      pkgIconBytesProvider((packageName: app.packageName, iconHash: hash)),
    );
    return asyncBytes.when(
      loading: () => fallback,
      error: (_, _) => fallback,
      data: (bytes) {
        if (bytes == null) return fallback;
        // 72 px main-tile paint footprint — see the parent
        // `CircleAppIcon(diameter: 72, ...)` in `_InstalledTile`. The
        // bridge ships full-resolution Android launcher PNGs (192 –
        // 512 px), so without `cacheWidth`/`cacheHeight` the engine
        // uploads a multi-megabyte texture per tile and the strip's
        // GPU cost balloons linearly with package count. dpr-scaled
        // so a 2× IVI still gets a crisp paint.
        final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
        final cacheSize = (72 * dpr).round();
        // gaplessPlayback so a rebuild between the same bytes (riverpod
        // re-emits during widget remounts) doesn't flash to fallback.
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
        );
      },
    );
  }
}
