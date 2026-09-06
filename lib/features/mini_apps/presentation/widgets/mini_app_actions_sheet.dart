/// Bottom sheet that surfaces "open on display N" + "uninstall" for a
/// long-pressed mini-app tile. Driven by [DisplayNativeBridge.list]
/// so the user only sees screens that actually exist on this car
/// (passenger only on Leopard 8, passenger + cluster on cars without
/// XDJA gating, etc.).
///
/// VehicleProfile-aware (since the 2026-05 trim-detection update):
///   * `display.hidden` — duplicate / shadow displays (e.g. display 3
///     on L8 is a logical mirror of 5) are pruned from the picker
///     so users don't have to guess which one is "real."
///   * `display.overrideLabel` — friendlier per-trim labels like
///     "Driver" replace the raw `Display.name` (which is typically
///     a vendor identifier the user can't parse).
///   * `display.clusterAvailable` — when the active VehicleProfile
///     reports the cluster isn't reachable on this trim (Leopard 5 /
///     5 Ultra / 7 / HAN L), the cluster tile carries a "may not
///     work on this car" caveat. We don't disable the tap — the
///     user might be on a firmware revision where it does work — but
///     we set expectations.
///
/// Bounce-back recovery (since the same release): some packages
/// (Waze, Google Maps, Spotify, YouTube) snap back to the IVI when
/// `am start --display N` lands them on a non-default display. The
/// host auto-recovers via `am stack move-task`; the resulting
/// `LaunchResult.path` is one of `am-start` (clean), `am-start-rePinned`
/// (recovered) or `am-start-bounced` (recovery failed). The sheet
/// surfaces all three so the user sees an honest result.
///
/// Cluster-pixel limit: on Leopard 8 the host returns
/// `path: 'overlay'` for cluster IDs without delivering pixels (see
/// project memory `project_leopard8_cluster_signature_gate`). The
/// sheet still surfaces those targets — the gesture-dispatch family
/// (Phase B) is the realistic capability there. Tagging cluster
/// targets visually so the user knows the limitation up front.
library;

import '../mini_app_install_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/_car_domain/display_labels.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../admin_mini_apps/domain/admin_dispatcher.dart';
import '../../runtime/display_native_bridge.dart';
import '../../runtime/display_snapshot.dart';
import '../../runtime/display_visibility.dart';
import '../../runtime/launch_outcome.dart';
import '../../domain/mini_app.dart';
import '../../data/installed_mini_app_store.dart';
import '../../state/favorite_mini_apps_providers.dart';
import '../../state/mini_app_providers.dart';
import '../../state/mini_app_update_checker.dart';
import '../../state/open_mini_app_on_display.dart';
import '../install_feedback.dart';

typedef OnUninstallRequested = void Function();
typedef OnOpenOnIviRequested = void Function();

/// Show the actions sheet. Returns when the sheet is dismissed; the
/// callbacks fire ahead of dismissal so the caller can use either
/// the future or the callbacks (the existing uninstall flow uses
/// callbacks).
Future<void> showMiniAppActionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required MiniApp app,
  required OnOpenOnIviRequested onOpenOnIvi,
  required OnUninstallRequested onUninstall,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) {
      return _Sheet(
        app: app,
        onOpenOnIvi: () {
          Navigator.of(sheetCtx).pop();
          onOpenOnIvi();
        },
        onUninstall: () {
          Navigator.of(sheetCtx).pop();
          onUninstall();
        },
      );
    },
  );
}

class _Sheet extends ConsumerStatefulWidget {
  const _Sheet({
    required this.app,
    required this.onOpenOnIvi,
    required this.onUninstall,
  });
  final MiniApp app;
  final VoidCallback onOpenOnIvi;
  final VoidCallback onUninstall;

  @override
  ConsumerState<_Sheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_Sheet> {
  late Future<List<DisplaySnapshot>> _displaysFuture;

  @override
  void initState() {
    super.initState();
    _displaysFuture = PlatformDisplayNativeBridge().list();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                widget.app.localizedName(
                  Localizations.localeOf(context).languageCode,
                ),
                style: theme.textTheme.titleMedium,
              ),
            ),
            // "Update available" entry only renders when the
            // user-driven update checker has flagged this app id —
            // see [MiniAppUpdateCheckerNotifier.checkNow].
            Consumer(
              builder: (ctx, ref, _) {
                final s = ref.watch(miniAppUpdateCheckerProvider);
                if (!miniAppUpdateAvailable(s, widget.app.id)) {
                  return const SizedBox.shrink();
                }
                return ListTile(
                  leading: Icon(
                    Icons.system_update_alt_rounded,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  title: Text(S.of(ctx).miniAppActionsUpdateAvailable),
                  subtitle: Text(S.of(ctx).miniAppActionsReinstallToUpgrade),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(ctx);
                    final notifier = ref.read(miniAppCatalogProvider.notifier);
                    // Capture the localizations before the await — `ctx`
                    // may be unmounted by the time the snackbar fires.
                    final updatedMsg = S
                        .of(ctx)
                        .miniAppActionsUpdated(widget.app.localizedName('en'));
                    try {
                      if (!await confirmMiniAppInstall(
                        ctx,
                        ref,
                        widget.app.id,
                      )) {
                        return;
                      }
                      await notifier.reinstall(widget.app.id);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      messenger.showSnackBar(
                        SnackBar(content: Text(updatedMsg)),
                      );
                      // Re-run the diff so the badge clears.
                      await ref
                          .read(miniAppUpdateCheckerProvider.notifier)
                          .checkNow();
                    } catch (e) {
                      if (ctx.mounted) {
                        showInstallErrorSnack(ctx, e);
                      }
                    }
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(S.of(context).miniAppActionsOpenHere),
              subtitle: Text(S.of(context).miniAppActionsOnThisScreen),
              onTap: widget.onOpenOnIvi,
            ),
            ListTile(
              leading: const Icon(Icons.security),
              title: const Text('Local permissions'),
              subtitle: const Text(
                'Review or revoke access for this installed bundle',
              ),
              onTap: () async {
                try {
                  final indexPath = await ref
                      .read(installedMiniAppStoreProvider)
                      .indexHtmlPath(widget.app.id);
                  if (!context.mounted || indexPath == null) return;
                  await ensureMiniAppLaunchConsent(
                    context,
                    ref,
                    widget.app,
                    indexPath,
                    forceReview: true,
                  );
                } catch (e) {
                  if (context.mounted) showInstallErrorSnack(context, e);
                }
              },
            ),
            _FavoriteToggleTile(appId: widget.app.id),
            FutureBuilder<List<DisplaySnapshot>>(
              future: _displaysFuture,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                // Drop the IVI (always available via "Open here") —
                // every other surface stays in the list. Shadow
                // duplicates (e.g. Display 3 on L8 mirrors 5) are
                // appended at the tail with dim styling instead of
                // being hidden, per `display_visibility.dart`. Long-
                // press grids should never silently drop a surface
                // the user can physically see.
                final displays = snap.data ?? const <DisplaySnapshot>[];
                final secondaries = displays.forPicker(excludeDefault: true);
                if (secondaries.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final d in secondaries)
                      _OpenOnDisplayTile(app: widget.app, display: d),
                  ],
                );
              },
            ),
            const Divider(height: 8),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                S.of(context).miniAppsUninstall,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: widget.onUninstall,
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenOnDisplayTile extends ConsumerWidget {
  const _OpenOnDisplayTile({required this.app, required this.display});
  final MiniApp app;
  final DisplaySnapshot display;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final label = _humanLabel(display);
    final caveat = _caveatFor(display);
    final tile = ListTile(
      leading: Icon(
        display.isCluster
            ? Icons.dashboard_customize_outlined
            : Icons.airplay_outlined,
      ),
      title: Text(label),
      subtitle: Text(caveat, style: theme.textTheme.bodySmall),
      onTap: () async {
        Navigator.of(context).pop();
        final messenger = ScaffoldMessenger.of(context);
        final s = S.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              s.miniAppActionsOpening(app.localizedName('en'), label),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
        final r = await openMiniAppOnDisplay(ref, app, displayId: display.id);
        if (r is AdminExecError) {
          messenger.showSnackBar(
            SnackBar(content: Text(s.miniAppActionsFailed(r.code))),
          );
        } else if (r is AdminExecOk) {
          // Single-sourced with the home-screen drop picker via
          // [classifyLaunchKind]. Critically this checks `ok`, not
          // just `path` — an `ok:false` envelope (e.g. an L5 DiShare
          // passenger/cluster cast the car refused) now reads as an
          // honest failure instead of a green "Opened on …".
          final kind = launchKindFromExecData(r.data);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                launchOutcomeMessage(
                  kind,
                  label: label,
                  path: r.data['path'] as String?,
                  error: r.data['error'],
                ),
              ),
              backgroundColor: kind.isFailure
                  ? theme.colorScheme.errorContainer
                  : null,
            ),
          );
        }
      },
    );
    // Same dim treatment as the other pickers — shadow surfaces are
    // tappable but rendered at reduced opacity so the user
    // intuitively reads them as secondary targets.
    return display.isDimmed ? Opacity(opacity: 0.55, child: tile) : tile;
  }

  /// Lifted to [displayHumanLabel] in `core/car/display_labels.dart`
  /// — single source of truth for the friendly label that surfaces
  /// in pickers, sheets, and the calibration tour. The local wrapper
  /// here keeps `(id=N)` suffix behaviour the action sheet always
  /// had, since the sheet shows multiple displays of the same role
  /// stacked together (the id disambiguates).
  String _humanLabel(DisplaySnapshot d) =>
      displayHumanLabel(d, includeIdSuffix: true);

  /// Two-line subtitle: dimensions, plus per-trim warnings.
  ///   * `clusterAvailable=false` — profile says no cluster on this
  ///     trim (Di5.0 family).
  ///   * `dimReason` — profile flagged this surface as a duplicate /
  ///     shadow (Di5.1 family — e.g. Display 3 mirrors 5).
  /// Multiple notes concatenate with `· ` so the user sees the full
  /// situation in one line.
  String _caveatFor(DisplaySnapshot d) {
    final parts = <String>['${d.width}×${d.height}'];
    if (d.isCluster) {
      parts.add(
        !d.clusterAvailable
            ? 'cluster not supported on this trim'
            : 'cluster — pixels may be vendor-gated',
      );
    }
    final dim = d.dimSubtitle;
    if (dim != null) parts.add(dim);
    return parts.join(' · ');
  }

  // Launch-result decoding moved to the shared, unit-pinned
  // [classifyLaunchKind] / [launchOutcomeMessage] in
  // `runtime/launch_outcome.dart` so this sheet and the home-screen
  // drop picker can't disagree about success vs failure (they used
  // to — see that file's header for the L5 false-success regression).
}

/// Toggle row for the home-strip favourites list. Reads the per-id
/// boolean off [isFavoriteMiniAppProvider] so the icon + label flip
/// instantly when the user taps. The tile dismisses the sheet on tap
/// — the snackbar is the confirmation; staying in the sheet would
/// hide the strip behind it.
class _FavoriteToggleTile extends ConsumerWidget {
  const _FavoriteToggleTile({required this.appId});
  final String appId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(isFavoriteMiniAppProvider(appId));
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        isFav ? Icons.star_rounded : Icons.star_border_rounded,
        color: isFav ? theme.colorScheme.primary : null,
      ),
      title: Text(isFav ? 'Remove from favourites' : 'Add to favourites'),
      subtitle: Text(
        isFav ? 'Hide from the home strip' : 'Show on the home screen strip',
      ),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        final addedNow = await ref
            .read(favoriteMiniAppIdsProvider.notifier)
            .toggle(appId);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              addedNow ? 'Added to favourites' : 'Removed from favourites',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }
}
