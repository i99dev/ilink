import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../kernel/playlists/catalogue_http_provider.dart';
import '../../kernel/storage/preferences.dart';
import '../../kernel/services/optional_services.dart';
import 'data/tv_catalog_api.dart';
import 'data/tv_catalog_cache.dart';
import 'data/tv_favorites_store.dart';
import 'data/tv_ivi_bridge.dart';
import 'domain/channel.dart';
import 'domain/country_order.dart';
import 'domain/tv_catalog.dart';
import 'domain/tv_quality.dart';
import 'domain/tv_state.dart';
import 'state/tv_catalog_controller.dart';
import 'tv_controller.dart';

/// All TV providers in one file — matches the project convention of keeping
/// feature-local DI together. Each provider has a single responsibility;
/// callers override the one they need for tests.
///
/// Three-layer content model the TV screen renders against:
///   1. **Catalogue** (iptv-rest-api JSON) — fetched lazily via
///      [TvCatalogController]; channels from a loaded group land in
///      [TvController]'s search index.
///   2. **Favourites** — full [Channel] snapshots (see [tvFavoritesStoreProvider]).
///   3. (v2) user-imported playlists — the kernel M3U parser already returns
///      neutral entries [Channel.fromM3uEntry] can map.

final tvFavoritesStoreProvider = Provider<TvFavoritesStore>((ref) {
  return TvFavoritesStore(ref.watch(sharedPreferencesProvider));
});

/// Persisted streaming-quality preference. The IVI player + the passenger
/// cast both read [TvQuality.maxBitrate] to cap the HLS variant on weak
/// connections. Survives restarts via shared preferences.
class TvQualityNotifier extends Notifier<TvQuality> {
  static const _key = 'tv_quality';

  @override
  TvQuality build() =>
      TvQuality.fromName(ref.watch(sharedPreferencesProvider).getString(_key));

  Future<void> set(TvQuality quality) async {
    if (quality == state) return;
    state = quality;
    await ref.read(sharedPreferencesProvider).setString(_key, quality.name);
  }
}

final tvQualityProvider = NotifierProvider<TvQualityNotifier, TvQuality>(
  TvQualityNotifier.new,
);

/// The main controller.
final tvControllerProvider = NotifierProvider<TvController, TvState>(
  TvController.new,
);

/// Launches the native full-screen IVI player (the only renderer that
/// works on this ROM). The browse page calls this on channel tap.
final tvIviBridgeProvider = Provider<TvIviBridge>((ref) {
  final bridge = TvIviBridge(
    streamingEnabled: () =>
        ref.mounted &&
        ref.read(serviceEnabledProvider(OptionalService.streaming)),
  );
  ref.listen(optionalServicesProvider, (_, next) {
    if (!(next.value?.contains(OptionalService.streaming) ?? false)) {
      unawaited(bridge.stop(networkOnly: true));
    }
  });
  return bridge;
});

/// Id of the channel last sent to the native player — drives the browse
/// grid's "playing" highlight (Flutter doesn't own native playback state).
class TvLastChannelNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final tvLastChannelProvider = NotifierProvider<TvLastChannelNotifier, String?>(
  TvLastChannelNotifier.new,
);

/// Version counter bumped whenever the favourites set mutates. Observers
/// subscribe to the counter (not the prefs blob, which has no change
/// stream). Same opaque-int pattern as radio's `favoritesVersionProvider`.
class TvFavoritesVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void signalChanged() => state = state + 1;
}

final tvFavoritesVersionProvider =
    NotifierProvider<TvFavoritesVersionNotifier, int>(
      TvFavoritesVersionNotifier.new,
    );

/// Resolved list of favourited channels. Re-fetches on every favourites
/// bump; `autoDispose` so it starts fresh on the next mount.
final favoriteChannelsProvider = FutureProvider.autoDispose<List<Channel>>((
  ref,
) {
  ref.watch(tvFavoritesVersionProvider);
  return ref.read(tvControllerProvider.notifier).favorites();
});

// --- Catalogue (iptv-rest-api) layer ------------------------------------

/// HTTP client for the catalogue JSON. Routes through the shared
/// [catalogueHttpProvider] (cdn Dio + license-token attach for the gate host).
final tvCatalogApiProvider = Provider<TvCatalogApi>((ref) {
  return TvCatalogApi(http: ref.watch(catalogueHttpProvider));
});

/// Persist-once cache for catalogue content (index + per-group payloads).
final tvCatalogCacheProvider = Provider<TvCatalogCache>((ref) {
  return TvCatalogCache(ref.watch(sharedPreferencesProvider));
});

/// Orchestrator. Cache-first reads; explicit refresh wipes cache + bumps
/// state so [tvCatalogIndexProvider] re-fetches.
final tvCatalogControllerProvider = NotifierProvider<TvCatalogController, int>(
  TvCatalogController.new,
);

/// Read-side view for the chip row. Watches the controller's op counter so a
/// refresh re-runs the future. Per the persist-once contract it returns the
/// cached value if present and hits the network only on first run / refresh.
final tvCatalogIndexProvider = FutureProvider<TvCatalogIndex>((ref) {
  ref.watch(tvCatalogControllerProvider);
  return ref.read(tvCatalogControllerProvider.notifier).getIndex();
});

/// A loaded channel group for [group]. `autoDispose` + `family` so each
/// selected chip resolves its own group; cache-first so re-selecting is
/// instant.
final tvChannelGroupProvider = FutureProvider.autoDispose
    .family<TvChannelGroup, TvCatalogGroup>((ref, group) {
      ref.watch(tvCatalogControllerProvider);
      return ref.read(tvCatalogControllerProvider.notifier).loadGroup(group);
    });

// --- Country ordering (user preference) ---------------------------------

/// The user's persisted country-ordering preference. Same prefs-backed
/// Notifier shape as [TvQualityNotifier]; the blob is keyed by country code
/// (stable across catalogue rebuilds — see [CountryOrderPref]).
class TvCountryOrderNotifier extends Notifier<CountryOrderPref> {
  static const _key = 'tv.country_order.v1';

  @override
  CountryOrderPref build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null || raw.isEmpty) return CountryOrderPref.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return CountryOrderPref.fromJson(decoded);
      }
    } catch (_) {
      // Corrupted blob — fall back to the default; next write overwrites.
    }
    return CountryOrderPref.empty;
  }

  Future<void> setMode(TvCountrySort mode) =>
      _commit(state.copyWith(mode: mode));

  /// Hide / show a single country (honoured in every sort mode).
  Future<void> setHidden(String code, bool hidden) {
    final next = Set<String>.of(state.hidden);
    if (hidden) {
      next.add(code);
    } else {
      next.remove(code);
    }
    return _commit(state.copyWith(hidden: next));
  }

  /// Move a country within the user's custom order. [order] is the FULL
  /// resolved code list as currently shown (the sheet hands us the post-move
  /// order); persisting the whole list keeps the custom order total even for
  /// countries the user never explicitly dragged. Switches the mode to
  /// [TvCountrySort.custom] so the new order takes effect.
  Future<void> applyCustomOrder(List<String> order) =>
      _commit(state.copyWith(mode: TvCountrySort.custom, customOrder: order));

  /// Back to catalogue order, nothing hidden.
  Future<void> reset() => _commit(CountryOrderPref.empty);

  Future<void> _commit(CountryOrderPref next) async {
    if (next == state) return;
    state = next;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, jsonEncode(next.toJson()));
  }
}

final tvCountryOrderProvider =
    NotifierProvider<TvCountryOrderNotifier, CountryOrderPref>(
      TvCountryOrderNotifier.new,
    );

/// **The single read surface for the country chip row.** Resolves the
/// catalogue's countries through the user's [CountryOrderPref] via the pure
/// [applyCountryOrder] transform. Both the chip row and the auto-select read
/// this (not `index.countries`) so they can never disagree on the order.
///
/// Recomputes only when the catalogue index or the preference changes, and the
/// transform runs on a small list (≲100 countries), so it's effectively free.
/// Returns an empty list until the index has loaded.
final orderedCountriesProvider = Provider<List<TvCatalogGroup>>((ref) {
  final countries =
      ref.watch(tvCatalogIndexProvider).value?.countries ?? const [];
  final pref = ref.watch(tvCountryOrderProvider);
  return applyCountryOrder(countries, pref);
});
