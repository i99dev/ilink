import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../domain/curated_playlist.dart';
import '../../domain/radio_facet.dart';
import '../../providers.dart';
import 'category_chips.dart';

/// Modal sheet for browsing the curated catalogue. The catalogue is faceted
/// (Categories / Countries / Languages), so instead of one flat list of every
/// playlist this sheet shows a facet chip-bar on top and lists only the
/// selected facet's playlists, with a search box that filters within it.
///
/// Pops the picked entry's `id` to the caller (radio_screen) which then calls
/// `CuratedPlaylistsController.loadPlaylist(...)`. The facet grouping is
/// precomputed once by [curatedFacetGroupsProvider] (memoised), so switching
/// facets is O(1) and the sheet stays smooth on the IVI even as the catalogue
/// grows. Per the persist-once contract it doesn't re-fetch on open;
/// "Refresh" (top-right) wipes the cache and re-fetches.
class CuratedPickerSheet extends ConsumerStatefulWidget {
  const CuratedPickerSheet({super.key});

  static Future<String?> show(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const CuratedPickerSheet(),
    );
  }

  @override
  ConsumerState<CuratedPickerSheet> createState() => _CuratedPickerSheetState();
}

class _CuratedPickerSheetState extends ConsumerState<CuratedPickerSheet> {
  /// Selected facet. Null until the user taps a chip — resolved to the first
  /// present facet so the sheet always opens on real content.
  RadioFacet? _facet;
  String _filter = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The group for the active facet, or the first present group as a default.
  FacetGroup? _selectedGroup(List<FacetGroup> groups) {
    if (groups.isEmpty) return null;
    if (_facet != null) {
      for (final g in groups) {
        if (g.facet == _facet) return g;
      }
    }
    return groups.first;
  }

  void _selectFacet(RadioFacet facet) {
    setState(() {
      _facet = facet;
      _filter = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final index = ref.watch(curatedIndexProvider);
    final groups = ref.watch(curatedFacetGroupsProvider);
    final selected = _selectedGroup(groups);
    return FractionallySizedBox(
      heightFactor: 0.85,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _grabber(cs),
            const SizedBox(height: 4),
            _header(context, cs),
            if (groups.length > 1) ...[
              const SizedBox(height: 10),
              _facetChips(groups, selected),
            ],
            const SizedBox(height: 8),
            _search(cs, selected),
            const SizedBox(height: 8),
            Expanded(child: _body(index, selected, cs)),
          ],
        ),
      ),
    );
  }

  Widget _grabber(ColorScheme cs) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      height: 4,
      width: 44,
      decoration: BoxDecoration(
        color: cs.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _header(BuildContext context, ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        Text(
          'CURATED RADIO',
          style: TextStyle(
            letterSpacing: 3,
            fontSize: 12,
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        IconButton(
          key: const Key('curated_picker.refresh'),
          tooltip: 'Refresh catalogue',
          icon: Icon(Icons.refresh_rounded, color: cs.onSurfaceVariant),
          onPressed: () async {
            await ref
                .read(curatedPlaylistsControllerProvider.notifier)
                .refresh();
          },
        ),
      ],
    ),
  );

  Widget _facetChips(List<FacetGroup> groups, FacetGroup? selected) {
    final selIdx = selected == null ? 0 : groups.indexOf(selected);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: CategoryChips(
        items: [
          for (final g in groups)
            CategoryChipItem(
              label: '${g.facet.plural} (${g.count})',
              icon: _facetIcon(g.facet),
            ),
        ],
        selectedIndex: selIdx < 0 ? 0 : selIdx,
        onChanged: (i) => _selectFacet(groups[i].facet),
      ),
    );
  }

  Widget _search(ColorScheme cs, FacetGroup? selected) {
    final hint = selected == null
        ? 'Search'
        : 'Search ${selected.count} ${selected.facet.plural.toLowerCase()}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        key: const Key('curated_picker.search'),
        controller: _searchController,
        onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
        style: TextStyle(color: cs.onSurface, fontSize: 14),
        decoration: InputDecoration(
          filled: true,
          fillColor: cs.surfaceContainer,
          hintText: hint,
          hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
        ),
      ),
    );
  }

  Widget _body(
    AsyncValue<CuratedIndex> index,
    FacetGroup? selected,
    ColorScheme cs,
  ) {
    return index.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Couldn\'t load the catalogue.\n\n$e\n\nTap Refresh to retry.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ),
      data: (_) {
        if (selected == null) {
          return Center(
            child: Text(
              'Catalogue is empty',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          );
        }
        final entries = _filter.isEmpty
            ? selected.entries
            : selected.entries
                  .where((e) => e.label.toLowerCase().contains(_filter))
                  .toList(growable: false);
        if (entries.isEmpty) {
          return Center(
            child: Text(
              'No ${selected.facet.plural.toLowerCase()} match "$_filter"',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          );
        }
        // ListView.builder (not .separated) so we can pass `prototypeItem`,
        // which pre-measures one row's height instead of measuring every row
        // during scroll. The separator is reserved INSIDE every row (see
        // [_EntryRow.showDivider]) so all rows — and the prototype — are the
        // same height; a per-row variant (divider only on i>0) would make
        // those rows 1px taller than the fixed prototype extent and overflow.
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: entries.length,
          prototypeItem: const _EntryRow(
            entry: CuratedIndexEntry(
              id: '',
              name: 'prototype',
              count: 0,
              urlPath: '',
            ),
            showDivider: true,
          ),
          itemBuilder: (context, i) =>
              _EntryRow(entry: entries[i], showDivider: i != 0),
        );
      },
    );
  }
}

IconData _facetIcon(RadioFacet f) => switch (f) {
  RadioFacet.category => Icons.category_rounded,
  RadioFacet.country => Icons.public_rounded,
  RadioFacet.language => Icons.translate_rounded,
  RadioFacet.other => Icons.library_music_rounded,
};

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, this.showDivider = false});
  final CuratedIndexEntry entry;

  /// Whether to draw the visible 1px separator above the tile. Every row
  /// reserves the 1px slot regardless (a transparent spacer when false) so
  /// all rows are the same height — `ListView.prototypeItem` pins a fixed
  /// extent, and an uneven row would overflow it by exactly 1px.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        showDivider
            ? Divider(height: 1, color: cs.outlineVariant)
            : const SizedBox(height: 1),
        ListTile(
          leading: Icon(_facetIcon(entry.facet), color: AppColors.accent),
          // Facet prefix stripped — the active chip already provides context.
          title: Text(entry.label, style: TextStyle(color: cs.onSurface)),
          trailing: Text(
            '${entry.count}',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          onTap: entry.id.isEmpty
              ? null
              : () => Navigator.of(context).pop(entry.id),
        ),
      ],
    );
  }
}
