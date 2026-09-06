import 'package:ilink/kernel/storage/local_first_image.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../domain/radio_state.dart';
import '../../domain/station.dart';
import '../../providers.dart';

/// One row in the station list — logo, name, country/bitrate, a play
/// button, and a favourite toggle.
class StationTile extends ConsumerWidget {
  const StationTile({super.key, required this.station, required this.onPlay});

  final Station station;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    // Narrow to the two derived booleans this tile renders — any other
    // RadioState transition (loading on a sibling station, error text
    // changing) must not repaint every tile in the grid.
    final (isCurrent, isPlaying) = ref.watch(
      radioControllerProvider.select((s) {
        final match = _currentId(s) == station.id;
        return (match, match && s is RadioPlaying);
      }),
    );
    // Subscribe to favourites-version bumps so the heart icon flips
    // immediately after `toggleFavorite` (the controller doesn't emit
    // a RadioState transition on favourite writes). Reading the counter
    // is enough — we don't need its value, just the rebuild signal.
    ref.watch(favoritesVersionProvider);
    final controller = ref.read(radioControllerProvider.notifier);
    final isFav = controller.isFavorite(station.id);

    return Material(
      color: isCurrent ? cs.surfaceContainerHigh : cs.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _Logo(favicon: station.favicon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      station.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(station),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: isFav ? 'Unfavorite' : 'Favorite',
                icon: Icon(
                  isFav
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  color: isFav ? AppColors.accent : cs.onSurfaceVariant,
                ),
                onPressed: () =>
                    controller.toggleFavorite(station.id, station: station),
              ),
              IconButton(
                tooltip: isPlaying ? 'Pause' : 'Play',
                icon: Icon(
                  isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: AppColors.primary,
                  size: 34,
                ),
                onPressed: () {
                  if (isPlaying) {
                    controller.pause();
                  } else {
                    onPlay();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _currentId(RadioState s) => switch (s) {
    RadioPlaying(:final station) => station.id,
    RadioPaused(:final station) => station.id,
    RadioLoading(:final station) => station.id,
    RadioError(:final station) => station?.id,
    RadioIdle() => null,
  };

  String _subtitle(Station s) {
    final parts = <String>[
      if (s.countryCode != null && s.countryCode!.isNotEmpty) s.countryCode!,
      if (s.codec != null && s.codec!.isNotEmpty) s.codec!,
      if (s.bitrate > 0) '${s.bitrate} kbps',
    ];
    if (parts.isEmpty && s.tags.isNotEmpty) parts.add(s.tags.first);
    return parts.join(' • ');
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.favicon});
  final String? favicon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const size = 44.0;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.outlineVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.radio_rounded, color: cs.onSurfaceVariant, size: 22),
    );
    if (favicon == null || favicon!.isEmpty) return placeholder;
    // Decode favicons at painted size × dpr so the radio list scrolls
    // smoothly even on a long station list — without this the
    // ListView holds dozens of full-resolution decoded bitmaps in
    // memory at once.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheSize = (size * dpr).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LocalFirstImage(
        service: OptionalService.streaming,
        imageUrl: favicon!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: cacheSize,
        memCacheHeight: cacheSize,
        placeholder: (context, url) => placeholder,
        errorWidget: (context, url, error) => placeholder,
      ),
    );
  }
}
