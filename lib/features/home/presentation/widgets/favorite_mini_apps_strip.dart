import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../mini_apps/domain/mini_app.dart';
import '../../../mini_apps/presentation/launch_mini_app.dart';
import '../../../mini_apps/presentation/widgets/mini_app_actions_sheet.dart';
import '../../../mini_apps/presentation/widgets/mini_app_remote_image.dart';
import '../../../mini_apps/presentation/widgets/my_apps_tab.dart'
    show confirmMiniAppUninstall;
import '../../../mini_apps/state/favorite_mini_apps_providers.dart';
import 'circle_app_icon.dart';

/// Lower-pane home strip — the user's favourite mini-apps, in the
/// order they arranged them. Tap launches; long-press surfaces the
/// shared mini-app actions sheet (same one the My Apps grid uses)
/// so add/remove favourite is a single mental model.
///
/// Lives inside [CarStatusPanel]'s 40 % flex slot; sized to fill it
/// without scrolling vertically. Horizontal overflow scrolls — the
/// strip can hold an arbitrary number of favourites without the
/// layout pushing the hero card around.
class FavoriteMiniAppsStrip extends ConsumerWidget {
  const FavoriteMiniAppsStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final favs = ref.watch(favoriteMiniAppsProvider);
    final lang = Localizations.localeOf(context).languageCode;
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
            Text(
              t.favoritesTitle,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurfaceVariant,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: favs.isEmpty
                  ? _Empty(hint: t.favoritesEmptyHint)
                  : _Strip(apps: favs, lang: lang),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          hint,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline, fontSize: 13, height: 1.4),
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  // App-Store-style vertical-scroll grid: generous spacing between
  // tiles, larger icons, single-line label, columns auto-fit to the
  // right pane's width. The 120 px max-extent gives ~5 columns on a
  // 600 px-wide pane, ~6+ on ultrawide head units, and gracefully
  // collapses to 3 on narrow trims. mainAxisSpacing > crossAxisSpacing
  // is intentional — vertical breathing reads cleaner on a card grid
  // than equal whitespace, same trick the App Store grid uses.
  static const _kTileMaxExtent = 120.0;
  static const _kCrossGap = 12.0;
  static const _kMainGap = 18.0;
  static const _kTileAspect = 0.92; // taller than wide → label has room

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
      itemBuilder: (ctx, i) => _FavoriteTile(app: apps[i], lang: lang),
    );
  }
}

class _FavoriteTile extends ConsumerWidget {
  const _FavoriteTile({required this.app, required this.lang});
  final MiniApp app;
  final String lang;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final name = app.localizedName(lang);
    // Width is owned by the parent grid (SliverGridDelegate sizes
    // each cell to ~100 px on the head unit's cross-axis). Inside the
    // cell the InkWell stretches to fill, so a tap anywhere on the
    // tile area registers — bigger touch surface than the previous
    // fixed-100 px box left.
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => openMiniApp(context, ref, app),
      onLongPress: () => showMiniAppActionsSheet(
        context,
        ref,
        app: app,
        onOpenOnIvi: () => openMiniApp(context, ref, app),
        onUninstall: () => confirmMiniAppUninstall(context, ref, appId: app.id),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 72 px circular icon. Matches the Apps tab tile + the
            // running-app chips inside the DISPLAYS picker so the
            // user perceives one app-tile vocabulary across every
            // surface. Wraps [MiniAppRemoteImage] (which has its
            // own network-fetch + cache strategy) in [CircleAppIcon]
            // for the shape + shadow.
            CircleAppIcon(
              diameter: 72,
              child: MiniAppRemoteImage(url: app.icon),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              // Single-line label — multi-line wrap on a 120 px tile
              // produces orphaned tail words ("Pkg / Launcher") that
              // read worse than a clean truncation. The full name is
              // available on long-press via the actions sheet.
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
      ),
    );
  }
}
