import 'package:ilink/kernel/storage/local_first_image.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../radio/domain/station.dart';
import '../../../radio/providers.dart';
import '../../../shell/state/active_screen_controller.dart';

/// Idle home-screen left pane — favourites only.
///
/// History: this tile previously embedded a `_VoiceCard` (large mic
/// + rotating "try saying…" examples) at the top. The mic moved to the
/// bottom shell row (FloatingMic) and the rotating examples pill was
/// removed entirely, so the home pane is fully focused on radio
/// discovery and there's exactly one voice affordance on screen.
/// Renamed-not-renamed because the tile is referenced from multiple home
/// layouts and this minimises churn.
class VoiceShortcutsTile extends ConsumerWidget {
  const VoiceShortcutsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: const _FavoritesSection(),
    );
  }
}

/// Favourites grid. Two columns of station cards on the home pane —
/// reads [favoriteStationsProvider] which auto-refreshes on every
/// `signalChanged` bump from [RadioController.toggleFavorite], so the
/// list stays live without manual wiring.
class _FavoritesSection extends ConsumerWidget {
  const _FavoritesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final favs = ref.watch(favoriteStationsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.favorite_rounded,
              color: AppColors.accent,
              size: 14,
            ),
            const SizedBox(width: 6),
            Text(
              t.voiceShortcutsFavoritesTitle,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 11,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            // Quick way to find new stations to favourite.
            TextButton.icon(
              onPressed: () =>
                  ref.read(activeScreenProvider.notifier).go(DashScreen.radio),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: Text(
                t.voiceShortcutsBrowseRadio,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: favs.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) =>
                _EmptyFavorites(message: t.voiceShortcutsFavoritesError),
            data: (stations) {
              if (stations.isEmpty) {
                return _EmptyFavorites(message: t.voiceShortcutsFavoritesEmpty);
              }
              // ClampingScrollPhysics matches the Android-native scroll
              // feel of the head-unit + skips the iOS overscroll
              // simulation work each frame; the IVI is not iOS so the
              // bounce was uncanny anyway.
              return GridView.builder(
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 2.6,
                ),
                itemCount: stations.length,
                itemBuilder: (_, i) => _FavoriteCard(station: stations[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FavoriteCard extends ConsumerWidget {
  const _FavoriteCard({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final controller = ref.read(radioControllerProvider.notifier);
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => controller.playStation(station),
        // Long-press unfavourites — same surgery as tapping the
        // heart in the Radio tab. Avoids us needing a dedicated
        // remove control on every card.
        onLongPress: () =>
            controller.toggleFavorite(station.id, station: station),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              _FavoriteIcon(favicon: station.favicon),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      station.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((station.countryCode ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        station.countryCode!.toUpperCase(),
                        style: TextStyle(
                          color: cs.outline,
                          fontSize: 10,
                          letterSpacing: 1.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteIcon extends StatelessWidget {
  const _FavoriteIcon({required this.favicon});

  final String? favicon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(36),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.radio_rounded, color: AppColors.accent, size: 18),
    );
    final url = favicon;
    if (url == null || url.isEmpty) {
      return SizedBox(width: 36, height: 36, child: fallback);
    }
    // Decode favicons at the painted 36-px resolution × dpr — radio
    // station favicons are commonly shipped at 256+ from the
    // streaming index, and on the IVI's GPU we'd otherwise upload a
    // ~256 KB texture per favourite. memCacheWidth/Height pegs the
    // bitmap to roughly 72 px on a 2× display ⇒ ~20 KB.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheSize = (36 * dpr).round();
    return SizedBox(
      width: 36,
      height: 36,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: cs.surfaceContainerHighest,
          child: LocalFirstImage(
            service: OptionalService.downloads,
            imageUrl: url,
            fit: BoxFit.cover,
            memCacheWidth: cacheSize,
            memCacheHeight: cacheSize,
            placeholder: (_, _) => fallback,
            errorWidget: (_, _, _) => fallback,
          ),
        ),
      ),
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border_rounded, size: 28, color: cs.outline),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
