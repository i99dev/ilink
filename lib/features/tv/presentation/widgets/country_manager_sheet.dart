import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/country_order.dart';
import '../../domain/tv_catalog.dart';
import '../../providers.dart';

/// Bottom sheet that lets the user order the TV country chips "as they want":
/// pick a sort preset, drag countries into a custom order, and hide ones they
/// never watch. Writes straight through [tvCountryOrderProvider]; the chip row
/// reacts via [orderedCountriesProvider].
Future<void> showTvCountryManager(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _CountryManagerSheet(),
  );
}

class _CountryManagerSheet extends ConsumerWidget {
  const _CountryManagerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final pref = ref.watch(tvCountryOrderProvider);
    final notifier = ref.read(tvCountryOrderProvider.notifier);

    // Show the FULL country set (including hidden ones, so they can be
    // un-hidden) in the current resolved order. We strip `hidden` from the
    // pref purely for ordering here — visibility is shown per-row instead.
    final all = ref.watch(tvCatalogIndexProvider).value?.countries ?? const [];
    final ordered = applyCountryOrder(all, pref.copyWith(hidden: const {}));

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Countries',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: pref == CountryOrderPref.empty
                        ? null
                        : () => notifier.reset(),
                    icon: const Icon(Icons.restore_rounded, size: 18),
                    label: const Text('Reset'),
                  ),
                ],
              ),
            ),
            _SortPresets(mode: pref.mode, onPick: (m) => notifier.setMode(m)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Drag to set your own order; tap the eye to hide a country.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            Flexible(
              child: ordered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text('No countries in the catalogue.'),
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: ordered.length,
                      // Flutter supplies the destination index after removal.
                      onReorderItem: (oldIndex, newIndex) {
                        final codes = ordered
                            .map((c) => c.key)
                            .toList(growable: true);
                        final moved = codes.removeAt(oldIndex);
                        codes.insert(newIndex, moved);
                        notifier.applyCustomOrder(codes);
                      },
                      itemBuilder: (context, i) {
                        final country = ordered[i];
                        return _CountryRow(
                          key: ValueKey(country.key),
                          country: country,
                          index: i,
                          hidden: pref.hidden.contains(country.key),
                          onToggleHidden: (h) =>
                              notifier.setHidden(country.key, h),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SortPresets extends StatelessWidget {
  const _SortPresets({required this.mode, required this.onPick});
  final TvCountrySort mode;
  final ValueChanged<TvCountrySort> onPick;

  static const _labels = {
    TvCountrySort.middleEast: 'Middle East',
    TvCountrySort.catalogDefault: 'Default',
    TvCountrySort.alpha: 'A–Z',
    TvCountrySort.channelCount: 'Most channels',
    TvCountrySort.custom: 'Custom',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final entry in _labels.entries) ...[
            ChoiceChip(
              label: Text(entry.value),
              selected: mode == entry.key,
              onSelected: (_) => onPick(entry.key),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required super.key,
    required this.country,
    required this.index,
    required this.hidden,
    required this.onToggleHidden,
  });

  final TvCatalogGroup country;
  final int index;
  final bool hidden;
  final ValueChanged<bool> onToggleHidden;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final flag = country.flag;
    return ListTile(
      dense: true,
      leading: ReorderableDragStartListener(
        index: index,
        child: Icon(Icons.drag_handle_rounded, color: cs.onSurfaceVariant),
      ),
      title: Text(
        (flag != null && flag.isNotEmpty)
            ? '$flag  ${country.name}'
            : country.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: hidden ? TextStyle(color: cs.onSurfaceVariant) : null,
      ),
      subtitle: Text('${country.count} channels'),
      trailing: IconButton(
        tooltip: hidden ? 'Show' : 'Hide',
        icon: Icon(
          hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          color: hidden ? cs.onSurfaceVariant : cs.primary,
        ),
        onPressed: () => onToggleHidden(!hidden),
      ),
    );
  }
}
