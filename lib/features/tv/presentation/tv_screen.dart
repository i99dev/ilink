import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/channel.dart';
import '../domain/tv_catalog.dart';
import '../providers.dart';
import 'widgets/channel_tile.dart';
import 'widgets/country_manager_sheet.dart';

/// Live-TV browse page: catalogue chips + search + a channel grid. Tapping
/// a channel starts it and opens the full-screen [ImmersiveTvScreen].
///
/// There is deliberately NO inline video here: on this BYD ROM an embedded
/// video surface goes black once the shell's PageView pushes this page
/// off-screen. Video lives only in the pushed immersive route, whose
/// surface is created fresh on every entry (and so always renders).
class TvScreen extends ConsumerStatefulWidget {
  const TvScreen({super.key});

  @override
  ConsumerState<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends ConsumerState<TvScreen> {
  /// Selected catalogue group; `null` means the Favourites pseudo-group.
  TvCatalogGroup? _selected;
  bool _autoSelected = false;
  String _query = '';
  Timer? _debounce;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = value.trim().toLowerCase());
    });
  }

  void _select(TvCatalogGroup? group) {
    setState(() {
      _selected = group;
      _autoSelected = true;
      _query = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final indexAsync = ref.watch(tvCatalogIndexProvider);
    // Resolve countries through the user's ordering preference. Auto-select
    // honours that order so the default chip is the user's first, not the
    // catalogue's.
    final orderedCountries = ref.watch(orderedCountriesProvider);

    if (!_autoSelected && _selected == null && orderedCountries.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_autoSelected) _select(orderedCountries.first);
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Chips(
            indexAsync: indexAsync,
            selected: _selected,
            onSelect: _select,
            onRefresh: () =>
                ref.read(tvCatalogControllerProvider.notifier).refresh(),
          ),
          const SizedBox(height: 10),
          _SearchField(
            controller: _searchController,
            onChanged: _onSearch,
            cs: cs,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _ChannelList(group: _selected, query: _query),
          ),
        ],
      ),
    );
  }
}

/// The channel grid for the selected group (or favourites), filtered by the
/// search query.
class _ChannelList extends ConsumerWidget {
  const _ChannelList({required this.group, required this.query});
  final TvCatalogGroup? group;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(tvFavoritesVersionProvider);
    final AsyncValue<List<Channel>> channelsAsync = group == null
        ? ref.watch(favoriteChannelsProvider)
        : ref.watch(tvChannelGroupProvider(group!)).whenData((g) => g.channels);

    return channelsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message(
        icon: Icons.cloud_off_rounded,
        text: group == null
            ? 'Could not load favourites'
            : 'Could not load channels.\n$e',
      ),
      data: (channels) {
        final filtered = query.isEmpty
            ? channels
            : channels
                  .where((c) => c.name.toLowerCase().contains(query))
                  .toList(growable: false);
        if (filtered.isEmpty) {
          return _Message(
            icon: group == null ? Icons.favorite_border : Icons.tv_off_rounded,
            text: group == null
                ? 'No favourites yet — pick a country and tap the heart.'
                : 'No channels match "$query".',
          );
        }
        return _Grid(channels: filtered);
      },
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid({required this.channels});
  final List<Channel> channels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(tvControllerProvider.notifier);
    final currentId = ref.watch(tvLastChannelProvider);

    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 64,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final c = channels[i];
        return ChannelTile(
          channel: c,
          playing: c.id == currentId,
          favorite: notifier.isFavorite(c.id),
          onTap: () async {
            // Native full-screen player owns playback (embedded video
            // can't render on this ROM). Hand it the browsable list for
            // in-player ◀/▶ + the quality cap.
            try {
              await ref
                  .read(tvIviBridgeProvider)
                  .play(
                    channels: channels,
                    startIndex: i,
                    maxBitrate: ref.read(tvQualityProvider).maxBitrate,
                  );
              ref.read(tvLastChannelProvider.notifier).set(c.id);
            } catch (error) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(error.toString())));
            }
          },
          onToggleFavorite: () => notifier.toggleFavorite(c.id, channel: c),
        );
      },
    );
  }
}

class _Chips extends ConsumerWidget {
  const _Chips({
    required this.indexAsync,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
  });

  final AsyncValue<TvCatalogIndex> indexAsync;
  final TvCatalogGroup? selected;
  final void Function(TvCatalogGroup?) onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 40,
      child: indexAsync.when(
        loading: () => const Center(
          child: SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (e, _) => Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 18),
            const SizedBox(width: 8),
            const Expanded(child: Text('Catalogue unavailable')),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: onRefresh,
            ),
          ],
        ),
        data: (index) {
          // Countries come from the ordering-aware provider (user sort +
          // hide); categories follow in catalogue order, after Favourites.
          final orderedCountries = ref.watch(orderedCountriesProvider);
          final groups = <TvCatalogGroup?>[
            null,
            ...orderedCountries,
            ...index.categories,
          ];
          return Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final g = groups[i];
                    final isSelected = g?.id == selected?.id;
                    final label = g == null
                        ? '★ Favourites'
                        : (g.flag != null && g.flag!.isNotEmpty
                              ? '${g.flag} ${g.name}'
                              : g.name);
                    return ChoiceChip(
                      label: Text(label),
                      selected: isSelected,
                      onSelected: (_) => onSelect(g),
                    );
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Sort & manage countries',
                onPressed: () => showTvCountryManager(context),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh catalogue',
                onPressed: onRefresh,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.cs,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search channels',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        filled: true,
        fillColor: cs.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
