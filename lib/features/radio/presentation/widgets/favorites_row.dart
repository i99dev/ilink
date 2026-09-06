import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../domain/station.dart';
import '../../providers.dart';

/// Horizontal scroller of favourited stations, rendered above the main
/// list. Empty when the user has no favourites yet.
///
/// Reactive: reads [favoriteStationsProvider], which re-fetches on
/// every [favoritesVersionProvider] bump. Tapping the heart on a
/// station tile flips this row without any extra plumbing.
class FavoritesRow extends ConsumerWidget {
  const FavoritesRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favs = ref.watch(favoriteStationsProvider);
    return favs.when(
      // Hold the slot height during the very first load so the list
      // below doesn't reflow on mount. Subsequent reloads after a
      // toggle keep the previous data visible (AsyncValue doesn't
      // revert to `loading` during a refresh unless we invalidate),
      // so this branch only fires on cold start.
      loading: () => const SizedBox(height: 72),
      error: (_, _) => const SizedBox.shrink(),
      data: (favorites) {
        if (favorites.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: favorites.length,
            separatorBuilder: (context, i) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final s = favorites[i];
              return _Pill(
                station: s,
                onTap: () =>
                    ref.read(radioControllerProvider.notifier).playStation(s),
              );
            },
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.station, required this.onTap});

  final Station station;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.favorite_rounded,
                color: AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  station.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
