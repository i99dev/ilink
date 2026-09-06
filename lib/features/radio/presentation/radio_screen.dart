import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/ui/responsive/spacing.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../domain/curated_playlist.dart';
import '../domain/radio_state.dart';
import '../domain/station.dart';
import '../providers.dart';
import 'widgets/category_chips.dart';
import 'widgets/curated_picker_sheet.dart';
import 'widgets/favorites_row.dart';
import 'widgets/my_playlists_sheet.dart';
import 'widgets/radio_search_bar.dart';
import 'widgets/station_tile.dart';

/// Top-level category strip. The radio screen renders against the
/// three-layer model — `curated` (m3u-rest-api JSON), `myPlaylists`
/// (user imports), and `favorites`. The first two open pickers and the
/// selection lives in [_RadioScreenState] as a filter; `favorites`
/// renders the persisted snapshots directly.
enum _Category { curated, favorites, myPlaylists }

class RadioScreen extends ConsumerStatefulWidget {
  const RadioScreen({super.key});

  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen> {
  /// First-launch lands on Curated with no selection — the empty state
  /// invites the user to tap the chip and pick a playlist.
  _Category _category = _Category.curated;
  String? _curatedFilter;
  String? _userPlaylistFilter;

  String _searchQuery = '';

  /// The list the body renders — recomputed whenever the user picks a
  /// new category / source / types in the search box. Held as a
  /// `Future<List<Station>>` so FutureBuilder handles the loading state.
  Future<List<Station>>? _results;

  /// Pending search-query change; fired once typing pauses for
  /// [_kSearchDebounce]. Coalesces a burst of keystrokes; without it
  /// every keystroke re-runs the in-memory filter and flickers.
  Timer? _searchDebounce;
  static const _kSearchDebounce = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _loadForCategory();
    // Don't leave the page empty on open: auto-load the user's saved default
    // playlist, or the fleet default region (Arabic) on a fresh install.
    unawaited(_autoSelectDefaultCurated());
  }

  /// Resolve and select the default curated playlist when the page opens with
  /// nothing chosen. Prefers the user's persisted pick
  /// ([radioDefaultPlaylistProvider]); otherwise falls back to the fleet
  /// default region ([kRadioDefaultRegionQuery] = Arabic), matched against the
  /// catalogue's facet labels. Async (needs the catalogue index); no-op if the
  /// user already picked something or the index can't load.
  Future<void> _autoSelectDefaultCurated() async {
    if (_curatedFilter != null) return;
    final ctrl = ref.read(curatedPlaylistsControllerProvider.notifier);
    final savedId = ref.read(radioDefaultPlaylistProvider);
    final CuratedIndex idx;
    try {
      idx = await ctrl.getIndex();
    } catch (_) {
      return; // offline / catalogue unavailable — keep the empty state's hint
    }
    if (!mounted || _curatedFilter != null) return;
    String? id;
    if (savedId != null && idx.entries.any((e) => e.id == savedId)) {
      id = savedId;
    } else {
      id = matchCuratedEntry(idx, kRadioDefaultRegionQuery)?.id;
    }
    if (id == null || !mounted) return;
    setState(() {
      _category = _Category.curated;
      _curatedFilter = id;
      _loadForCategory();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radio = ref.watch(radioControllerProvider);
    // Favourite + user-playlist mutations don't emit a RadioState
    // transition. Re-run the load so the list reflects the change in
    // place when the user is viewing that category.
    ref.listen<int>(favoritesVersionProvider, (_, _) {
      if (_category == _Category.favorites) setState(_loadForCategory);
    });
    ref.listen<int>(userPlaylistsVersionProvider, (_, _) {
      if (_category == _Category.myPlaylists) setState(_loadForCategory);
    });
    // Deep-link "Open with iLINK" claim — M3uPlaylistLinkHandler
    // stakes the id of a freshly-imported playlist; we honour it once
    // and clear, regardless of which category was active. Also pick up
    // any claim landed BEFORE first build (cold-start path) via a
    // post-frame check below.
    ref.listen<String?>(pendingUserPlaylistProvider, (_, next) {
      if (next != null) _honourPendingClaim(next);
    });
    final pending = ref.read(pendingUserPlaylistProvider);
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _honourPendingClaim(pending),
      );
    }

    final cs = Theme.of(context).colorScheme;
    final pad = Spacing.md(context);
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(onRefresh: _reloadCurrent),
          const SizedBox(height: 10),
          RadioSearchBar(onChanged: _onSearchChanged),
          const SizedBox(height: 10),
          _buildChips(),
          const SizedBox(height: 10),
          const FavoritesRow(),
          const SizedBox(height: 10),
          _NowPlayingBanner(state: radio),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reloadCurrent(),
              color: AppColors.accent,
              backgroundColor: cs.surfaceContainer,
              child: _StationList(future: _results, query: _searchQuery),
            ),
          ),
        ],
      ),
    );
  }

  // --- Chips ----------------------------------------------------------------

  Widget _buildChips() {
    final t = S.of(context);
    // English-only Curated / My Playlists labels by design — localise
    // alongside the next non-feature string addition.
    final curatedLabel = _resolveCuratedChipLabel();
    final userPlaylistLabel = _resolveUserPlaylistChipLabel();
    final items = <CategoryChipItem>[
      CategoryChipItem(label: curatedLabel, icon: Icons.library_music_rounded),
      CategoryChipItem(
        label: t.radioCategoryFavorites,
        icon: Icons.favorite_rounded,
      ),
      CategoryChipItem(
        label: userPlaylistLabel,
        icon: Icons.playlist_play_rounded,
      ),
    ];
    return CategoryChips(
      items: items,
      selectedIndex: _Category.values.indexOf(_category),
      onChanged: _onCategoryTapped,
    );
  }

  /// Resolve the Curated chip label to the picked entry's display name
  /// when one is loaded — falls back to "Curated" otherwise.
  String _resolveCuratedChipLabel() {
    final id = _curatedFilter;
    if (id == null) return 'Curated';
    final idx = ref.read(curatedIndexProvider);
    return idx.maybeWhen(
      data: (i) {
        final found = i.entries.where((e) => e.id == id);
        return found.isEmpty ? 'Curated' : 'Curated: ${found.first.name}';
      },
      orElse: () => 'Curated',
    );
  }

  Future<void> _onCategoryTapped(int index) async {
    final next = _Category.values[index];
    switch (next) {
      case _Category.curated:
        // Re-use existing selection when bouncing from another tab;
        // only open the picker on first visit OR when the user taps
        // the chip while already on Curated ("change playlist").
        if (_curatedFilter != null && _category != _Category.curated) {
          setState(() {
            _category = next;
            _loadForCategory();
          });
          return;
        }
        final picked = await CuratedPickerSheet.show(context);
        if (picked == null) return;
        // Remember the user's choice as their default so it sticks next open
        // (mirrors the TV country preference).
        unawaited(ref.read(radioDefaultPlaylistProvider.notifier).set(picked));
        setState(() {
          _category = next;
          _curatedFilter = picked;
          _loadForCategory();
        });
        break;
      case _Category.favorites:
        setState(() {
          _category = next;
          _loadForCategory();
        });
        break;
      case _Category.myPlaylists:
        // Re-use the existing pick when bouncing to this tab from
        // elsewhere; only open the sheet when no playlist is loaded yet
        // OR the user tapped the chip while already on this tab
        // ("change playlist").
        if (_userPlaylistFilter != null && _category != _Category.myPlaylists) {
          setState(() {
            _category = next;
            _loadForCategory();
          });
          return;
        }
        final picked = await MyPlaylistsSheet.show(context);
        if (picked == null) return;
        setState(() {
          _category = next;
          _userPlaylistFilter = picked;
          _loadForCategory();
        });
        break;
    }
  }

  /// Display label for the My Playlists chip. Reads the current
  /// selection's name from the store when one is loaded.
  String _resolveUserPlaylistChipLabel() {
    final id = _userPlaylistFilter;
    if (id == null) return 'My Playlists';
    final pl = ref.read(userPlaylistsProvider).where((p) => p.id == id);
    return pl.isEmpty ? 'My Playlists' : 'My Playlists: ${pl.first.name}';
  }

  // --- Data loading ---------------------------------------------------------

  void _loadForCategory() {
    final controller = ref.read(radioControllerProvider.notifier);
    final q = _searchQuery.trim().toLowerCase();
    switch (_category) {
      case _Category.curated:
        final id = _curatedFilter;
        if (id == null) {
          // Empty state guides user to tap chip → picker.
          _results = Future.value(const <Station>[]);
          break;
        }
        final ctrl = ref.read(curatedPlaylistsControllerProvider.notifier);
        _results = ctrl.getIndex().then((idx) {
          final entry = idx.entries.where((e) => e.id == id);
          if (entry.isEmpty) {
            // The cached selection no longer exists in the (refreshed)
            // catalogue — clear so the chip label resets.
            _curatedFilter = null;
            return const <Station>[];
          }
          return ctrl
              .loadPlaylist(entry.first)
              .then((pl) => _filter(pl.stations, q));
        });
        break;
      case _Category.favorites:
        _results = controller.favorites().then((all) => _filter(all, q));
        break;
      case _Category.myPlaylists:
        final id = _userPlaylistFilter;
        if (id == null) {
          _results = Future.value(const <Station>[]);
          break;
        }
        final all = ref.read(userPlaylistsProvider);
        final pl = all.where((p) => p.id == id);
        if (pl.isEmpty) {
          // The playlist was removed while this tab held its id; clear
          // the filter so the empty state explains.
          _userPlaylistFilter = null;
          _results = Future.value(const <Station>[]);
          break;
        }
        final stations = pl.first.stations;
        controller.indexStations(
          stations,
        ); // belt+braces; importer also does it
        _results = Future.value(_filter(stations, q));
        break;
    }
  }

  /// Case-insensitive substring filter on name + tags. Lives here (not
  /// in the controller) because it's purely a presentation concern.
  List<Station> _filter(List<Station> all, String q) {
    if (q.isEmpty) return all;
    return all
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              s.tags.any((t) => t.toLowerCase().contains(q)),
        )
        .toList(growable: false);
  }

  void _onSearchChanged(String value) {
    final trimmed = value.trim();
    _searchDebounce?.cancel();
    if (_searchQuery == trimmed) return;
    _searchDebounce = Timer(_kSearchDebounce, () {
      if (!mounted) return;
      setState(() {
        _searchQuery = trimmed;
        // Keep the prior `_results` in place until the debounced load
        // is queued — FutureBuilder keeps painting the old list until
        // the new one resolves. Avoids an empty-list flash mid-typing.
        _loadForCategory();
      });
    });
  }

  Future<void> _reloadCurrent() async {
    if (!mounted) return;
    setState(_loadForCategory);
  }

  /// React to a "Open with iLINK" import: switch to My Playlists with
  /// the new id selected, then drop the claim so re-entering the screen
  /// doesn't keep re-applying it.
  void _honourPendingClaim(String id) {
    if (!mounted) return;
    setState(() {
      _category = _Category.myPlaylists;
      _userPlaylistFilter = id;
      _loadForCategory();
    });
    ref.read(pendingUserPlaylistProvider.notifier).clear();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          S.of(context).screenRadio.toUpperCase(),
          style: TextStyle(
            letterSpacing: 3,
            fontSize: 12,
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: S.of(context).actionRefresh,
          icon: Icon(
            Icons.refresh_rounded,
            color: cs.onSurfaceVariant,
            size: 20,
          ),
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

/// Starts [station] and surfaces a failure to the driver.
///
/// `RadioController.playStation` funnels every error into a
/// `CommandOutcome.failure` instead of throwing, so a caller that discards
/// the outcome turns any playback failure into a silent no-op — the tap
/// does nothing and nothing explains why. Errors raised before the player
/// emits its first state (a revoked streaming consent, a malformed stream
/// URL) never reach the now-playing banner either, so this is the only
/// place they can be reported.
Future<void> _playAndReport(
  BuildContext context,
  WidgetRef ref,
  Station station,
) async {
  // Resolve both before the await — the element may be gone afterwards.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final t = S.of(context);
  final outcome = await ref
      .read(radioControllerProvider.notifier)
      .playStation(station);
  if (outcome.ok || messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(content: Text(t.radioError(outcome.message ?? station.name))),
    );
}

class _StationList extends ConsumerWidget {
  const _StationList({required this.future, required this.query});

  final Future<List<Station>>? future;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<List<Station>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final t = S.of(context);
        if (snap.hasError) {
          return ListView(
            // Allow pull-to-refresh on an error screen — RefreshIndicator
            // needs a scrollable child, so a ListView wrapper unlocks the
            // retry gesture even when no data came back.
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 80),
              Center(
                child: Text(
                  t.radioFailedToLoad(snap.error.toString()),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          );
        }
        final items = snap.data ?? const <Station>[];
        if (items.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 80),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      query.isEmpty
                          ? t.radioNoStations
                          : t.radioNoResults(query),
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    if (query.isEmpty) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          t.radioNoStationsHint,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        }
        // `prototypeItem` lets the engine size every off-screen tile
        // from one measurement instead of laying out each row to learn
        // its height — meaningful on a long list where the first paint
        // otherwise stalls while the engine measures every row. 72 px
        // matches StationTile's actual painted height (Material
        // padding 10 + 44 logo + 10 = 64) plus the 8 px gap.
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: items.length,
          prototypeItem: const SizedBox(height: 72),
          itemBuilder: (context, i) {
            final s = items[i];
            return Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: StationTile(
                station: s,
                onPlay: () => _playAndReport(context, ref, s),
              ),
            );
          },
        );
      },
    );
  }
}

class _NowPlayingBanner extends StatelessWidget {
  const _NowPlayingBanner({required this.state});
  final RadioState state;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = switch (state) {
      RadioIdle() => null,
      RadioLoading(:final station) => t.radioLoading(station.name),
      RadioPlaying(:final station) => t.radioPlaying(station.name),
      RadioPaused(:final station) => t.radioPaused(station.name),
      RadioError(:final message) => t.radioError(message),
    };
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onSurface, letterSpacing: 1),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
