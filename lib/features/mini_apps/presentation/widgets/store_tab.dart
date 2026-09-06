import '../mini_app_install_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/i18n/locale_controller.dart';
import '../../domain/mini_app.dart';
import '../../state/category_providers.dart';
import '../../state/mini_app_sections.dart';
import '../../state/mini_app_install_gate.dart';
import '../../state/mini_app_providers.dart';
import '../../state/mini_app_update_checker.dart';
import '../../state/mini_app_view_mode.dart';
import '../install_feedback.dart';
import 'mini_app_details_modal.dart';
import 'mini_app_list_row.dart';
import 'mini_app_status_chips.dart';
import 'mini_app_tile.dart';

/// Store tab — every app the catalog exposes, with an Install /
/// Uninstall button per row.
///
/// Layout adapts to [miniAppViewModeProvider]:
///   * `grid` — card layout for visual browsing.
///   * `list` — dense rows for scanning many apps at once.
///
/// Install errors surface via SnackBar with a friendly headline +
/// the underlying exception message — see [showInstallErrorSnack].
/// Tile body itself isn't tappable in the Store; users launch from
/// My Apps where the beta-consent sheet + driver-safety gate run.
class StoreTab extends ConsumerWidget {
  const StoreTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final async = ref.watch(miniAppCatalogProvider);
    final lang =
        ref.watch(
          localeControllerProvider.select((a) => a.value?.locale.languageCode),
        ) ??
        Localizations.localeOf(context).languageCode;
    final viewMode = ref.watch(miniAppViewModeProvider);
    // Bootstrap the auto-refresh controller. Lazy by design — the
    // first widget that reads it kicks the timer off, and Riverpod
    // keeps it alive for the rest of the session.

    return RefreshIndicator(
      onRefresh: () => ref.read(miniAppCatalogProvider.notifier).refresh(),
      child: async.when(
        skipLoadingOnRefresh: true,
        skipError: true,
        loading: () => const _CenteredProgress(),
        error: (_, _) => _MessageList(message: t.miniAppsLoadError),
        data: (apps) {
          if (apps.isEmpty) {
            return _MessageList(message: t.miniAppsEmptyStore);
          }
          // Client-side category filter on the already-fetched
          // catalog. Cheap up to the SDK plan's 200-app threshold;
          // past that, the chip-tap should re-fetch with
          // ``?category=<slug>`` (server-side filter), tracked in
          // the SDK plan as a follow-up.
          //
          // Developer-category apps are gated on flight-test mode —
          // hidden from the regular Store, visible once the user
          // opts in via Settings → Developer. Single source of truth
          // is [flightTestEnabledProvider]; the chip rail and the
          // catalog filter both read it so toggling the setting
          // propagates atomically.
          final selected = ref.watch(selectedCategoryProvider);
          final flightTestOn = ref.watch(flightTestEnabledProvider);
          var filtered = apps;
          if (!flightTestOn) {
            filtered = filtered
                .where((a) => a.category != 'developer')
                .toList();
          }
          if (selected != null) {
            filtered = filtered.where((a) => a.category == selected).toList();
          }
          final body = viewMode == MiniAppViewMode.list
              ? _StoreList(apps: filtered, lang: lang)
              : _StoreGrid(apps: filtered, lang: lang);
          return Column(
            children: [
              const _CheckForUpdatesAction(),
              const _CategoryChipRail(),
              Expanded(
                child: filtered.isEmpty
                    ? _MessageList(message: t.miniAppsEmptyStore)
                    : body,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StoreGrid extends StatelessWidget {
  const _StoreGrid({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: apps.length,
      itemBuilder: (ctx, i) {
        final app = apps[i];
        return Consumer(
          builder: (ctx, ref, _) => MiniAppTile(
            app: app,
            languageCode: lang,
            // Tap → details modal (privileges, description, big CTA).
            onTap: () => showMiniAppDetails(ctx, ref, app, languageCode: lang),
            // The legacy Beta-only badge slot now carries the chip
            // strip (BETA + PRIVILEGED + SAFE-WHILE-DRIVING).
            betaBadge: MiniAppStatusChips(app: app),
            primary: _InstallButton(
              appId: app.id,
              isInstalled: app.isInstalled,
            ),
          ),
        );
      },
    );
  }
}

class _StoreList extends StatelessWidget {
  const _StoreList({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: apps.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final app = apps[i];
        return Consumer(
          builder: (ctx, ref, _) => MiniAppListRow(
            app: app,
            languageCode: lang,
            onTap: () => showMiniAppDetails(ctx, ref, app, languageCode: lang),
            trailing: _InstallButton(
              appId: app.id,
              isInstalled: app.isInstalled,
              compact: true,
            ),
          ),
        );
      },
    );
  }
}

class _InstallButton extends ConsumerWidget {
  const _InstallButton({
    required this.appId,
    required this.isInstalled,
    this.compact = false,
  });

  final String appId;
  final bool isInstalled;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final label = isInstalled ? t.miniAppsUninstall : t.miniAppsInstall;

    Future<void> onPressed() async {
      if (!isInstalled && !await confirmMiniAppInstall(context, ref, appId)) {
        return;
      }
      final gate = ref.read(miniAppInstallGateProvider);
      final outcome = isInstalled
          ? await gate.uninstall(
              caller: StoreTabInstaller.instance,
              appId: appId,
            )
          : await gate.install(
              caller: StoreTabInstaller.instance,
              appId: appId,
            );
      if (context.mounted) showInstallOutcomeSnack(context, outcome);
    }

    final style = compact
        ? FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          )
        : null;
    final outlinedStyle = compact
        ? OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          )
        : null;

    if (isInstalled) {
      return OutlinedButton(
        onPressed: onPressed,
        style: outlinedStyle,
        child: Text(label),
      );
    }
    return FilledButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

class _CenteredProgress extends StatelessWidget {
  const _CenteredProgress();
  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// Uses a [ListView] so the RefreshIndicator's pull-to-refresh
/// gesture still works when the content is a single centered line —
/// a plain Center wouldn't expose a scrollable for the refresh gesture
/// to hook into.
class _MessageList extends StatelessWidget {
  const _MessageList({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 120),
      children: [
        Center(
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// Horizontal chip rail at the top of the store tab. The leftmost
/// chip is "All" (selection: ``null``); each subsequent chip is one
/// canonical category slug fetched from
/// ``GET /api/v1/mini-apps/categories``.
///
/// Slugs come from the backend so adding a category is a backend
/// deploy, not a Flutter release. The API client returns a static
/// fallback list when the network is down so the rail still renders.
///
/// Filtering is client-side on the already-fetched catalog (cheap up
/// to the SDK plan's 200-app threshold); past that the chip-tap
/// should re-fetch with ``?category=<slug>`` per the migration
/// trigger documented in the SDK plan.
class _CategoryChipRail extends ConsumerWidget {
  const _CategoryChipRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedCategoryProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final flightTestOn = ref.watch(flightTestEnabledProvider);
    // Fallback while the categories request is in flight: render
    // just the "All" chip — never blocks the catalog grid.
    var slugs = categoriesAsync.maybeWhen(
      data: (s) => s,
      orElse: () => const <String>[],
    );
    // Hide the `developer` chip until flight-test mode is on. Same
    // gate filters the catalog so the rail and the body agree —
    // see the catalog filter in [StoreTab.build].
    if (!flightTestOn) {
      slugs = slugs.where((s) => s != 'developer').toList(growable: false);
    }

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: slugs.length + 1, // +1 for the "All" chip at the head
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _CategoryChip(
              label: 'All',
              selected: selected == null,
              onTap: () =>
                  ref.read(selectedCategoryProvider.notifier).select(null),
            );
          }
          final slug = slugs[i - 1];
          return _CategoryChip(
            label: _slugLabel(slug),
            selected: selected == slug,
            onTap: () =>
                ref.read(selectedCategoryProvider.notifier).select(slug),
          );
        },
      ),
    );
  }

  /// Title-case the slug for display. Backend slugs are lowercase
  /// kebab-case; users see proper-case English. Localization for
  /// these labels lands when the chip rail picks up a category-
  /// specific locale key — out of scope for v1.
  static String _slugLabel(String slug) {
    if (slug.isEmpty) return slug;
    return slug[0].toUpperCase() + slug.substring(1);
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: cs.primaryContainer,
      labelStyle: theme.textTheme.labelMedium?.copyWith(
        color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CheckForUpdatesAction extends ConsumerWidget {
  const _CheckForUpdatesAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = ref.watch(miniAppUpdateCheckerProvider);
    final relative = _relativeAge(s.lastCheckedAt);
    final updatable = s.updatable.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          if (updatable > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$updatable update${updatable == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          if (relative != null)
            Expanded(
              child: Text(
                'Last checked: $relative',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          OutlinedButton.icon(
            onPressed: s.checking ? null : () => _onCheck(context, ref),
            icon: s.checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: Text(s.checking ? 'Checking…' : 'Check for updates'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onCheck(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(miniAppUpdateCheckerProvider.notifier).checkNow();
    if (!context.mounted) return;
    final s = ref.read(miniAppUpdateCheckerProvider);
    final t = S.of(context);
    if (s.lastError != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.miniAppStoreUpdatesFailed('${s.lastError}'))),
      );
      return;
    }
    final n = s.updatable.length;
    if (n == 0) {
      messenger.showSnackBar(SnackBar(content: Text(t.miniAppStoreUpToDate)));
      return;
    }
    // Name the apps so the user knows what's pending without
    // navigating to My Apps. Truncate at three names to keep the
    // snackbar single-line; the rest are summarised numerically.
    final lang = Localizations.localeOf(context).languageCode;
    final names = s.updatable
        .take(3)
        .map((u) => u.app.localizedName(lang))
        .join(', ');
    final more = n > 3 ? ' +${n - 3} more' : '';
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.miniAppStoreUpdatesList('$names$more')),
        action: SnackBarAction(
          label: 'See',
          onPressed: () => _showUpdatesDialog(context, ref, lang),
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _showUpdatesDialog(BuildContext context, WidgetRef ref, String lang) {
    // The snackbar's "See" can fire after the user has navigated off
    // the Store tab — the captured `context` is then unmounted and any
    // inherited-widget lookup (Localizations, Navigator) throws
    // (Sentry I99DASH-3). Bail before touching either.
    if (!context.mounted) return;
    final updatable = ref.read(miniAppUpdateCheckerProvider).updatable;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final t = S.of(ctx);
        return AlertDialog(
          title: Text(t.miniAppStoreUpdatesAvailableTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final u in updatable)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.system_update_alt_rounded),
                  title: Text(u.app.localizedName(lang)),
                  subtitle: Text(t.miniAppStoreUpdatesTip),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.actionClose),
            ),
          ],
        );
      },
    );
  }

  String? _relativeAge(DateTime? at) {
    if (at == null) return null;
    final delta = DateTime.now().toUtc().difference(at.toUtc());
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }
}
