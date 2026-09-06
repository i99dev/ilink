import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/i18n/locale_controller.dart';
import '../../domain/mini_app.dart';
import '../../state/mini_app_providers.dart';
import '../../state/mini_app_view_mode.dart';
import 'mini_app_list_row.dart';
import 'mini_app_tile.dart';

class FlightTestTab extends ConsumerWidget {
  const FlightTestTab({super.key});

  /// Public docs URL the empty-state CTA opens. Lifted to a constant so
  /// tests can override it via Riverpod, and so a URL change doesn't
  /// require a code change in three places.
  static const docsUrl = 'https://github.com/i99dev/ilink#readme';

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
    // Same auto-refresh bootstrap pattern as StoreTab — keeps the
    // catalog warm while the tester has the tab open.

    return RefreshIndicator(
      onRefresh: () => ref.read(miniAppCatalogProvider.notifier).refresh(),
      child: async.when(
        skipLoadingOnRefresh: true,
        skipError: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _CenteredMessage(message: t.miniAppsLoadError),
        data: (apps) {
          // Filter to beta-track entries only. The catalog already
          // applied the (tester_user_id == user_id AND status == accepted)
          // gate server-side; client-side filtering is just narrowing
          // for display.
          final betaApps = apps.where((a) => a.isBeta).toList();
          if (betaApps.isEmpty) {
            return _FlightTestEmptyState();
          }
          return viewMode == MiniAppViewMode.list
              ? _FlightTestList(apps: betaApps, lang: lang)
              : _FlightTestGrid(apps: betaApps, lang: lang);
        },
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Min-height matches typical tab body so pull-to-refresh works
      // even on the empty error state.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Renders when the user has flight-test mode on but no beta apps
/// active — the most common state for a tester between flights.
/// Shows a clear next-action ("Request beta access" → docs) so the
/// surface isn't a confusing dead end.
class _FlightTestEmptyState extends StatelessWidget {
  Future<void> _openDocs(BuildContext context) async {
    final uri = Uri.parse(FlightTestTab.docsUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).miniAppsFlightTestEmptyOpenDocsFailed),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.flight_takeoff_rounded,
                    size: 48,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t.miniAppsFlightTestEmptyTitle,
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t.miniAppsFlightTestEmptyBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _openDocs(context),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(t.miniAppsFlightTestEmptyCta),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// List-mode renderer. Reuses [MiniAppListRow] so the look matches
/// the My Apps / Store tabs exactly — the only difference is the
/// pre-filtered input set.
class _FlightTestList extends StatelessWidget {
  const _FlightTestList({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: apps.length,
      itemBuilder: (_, i) => MiniAppListRow(app: apps[i], languageCode: lang),
    );
  }
}

/// Grid-mode renderer. Same tile + spacing as Store / My Apps; the
/// BETA badge per-tile already exists on [MiniAppTile] so testers
/// see exactly which version is on the beta track.
class _FlightTestGrid extends StatelessWidget {
  const _FlightTestGrid({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: apps.length,
      itemBuilder: (_, i) => MiniAppTile(app: apps[i], languageCode: lang),
    );
  }
}
