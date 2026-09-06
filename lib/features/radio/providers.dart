import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../kernel/api/dio_factory.dart';
import '../../kernel/services/optional_services.dart';
import '../../kernel/services/local_media.dart';
import '../../kernel/playlists/catalogue_http_provider.dart';
import '../../kernel/storage/preferences.dart';

// `sharedPreferencesProvider` was promoted to kernel/storage so the TV
// feature can share one prefs handle. Re-exported here so existing radio
// (and main.dart) imports of it keep resolving unchanged.
export '../../kernel/storage/preferences.dart' show sharedPreferencesProvider;
import 'data/curated_cache.dart';
import 'data/curated_playlist_api.dart';
import 'data/just_audio_radio_player.dart';
import 'data/radio_favorites_store.dart';
import 'data/radio_player.dart';
import 'data/user_playlist_importer.dart';
import 'data/user_playlist_store.dart';
import 'domain/curated_playlist.dart';
import 'domain/radio_state.dart';
import 'domain/station.dart';
import 'domain/user_playlist.dart';
import 'radio_controller.dart';
import 'state/curated_playlists_controller.dart';
import 'state/user_playlist_controller.dart';

/// All radio providers in one file — matches the project's convention of
/// keeping feature-local DI together. Each provider has a single
/// responsibility; callers override the one they need for testing instead
/// of monkey-patching.
///
/// The three-layer content model the radio screen renders against:
///   1. Bundled demos (assets) — see `data/demo_playlists.dart`.
///   2. User-imported playlists — store + controller added in the BYO
///      phases; the controller bumps [userPlaylistsVersionProvider] on
///      change so observers (incl. [RadioController]'s search index)
///      refresh.
///   3. Favourites — see [radioFavoritesStoreProvider].
///
/// There is intentionally NO remote-catalogue / TTL-cache layer: the
/// previous M3U-fork-via-GitHub fetcher (CachedRadioDirectoryApi +
/// FilePlaylistCache + RadioCacheStore + GithubPlaylistApi +
/// PlaylistCatalog + RawPlaylistClient) is gone — discovery is now
/// bundled-demos-plus-user-uploads, no network catalogue.

/// One-shot init for the just_audio_background MediaSession host.
/// Used to live in `main()._bootstrap()` — every cold boot paid for
/// the platform-channel handshake even on app sessions where the user
/// never tapped Play. Now triggered lazily on first read of
/// [radioPlayerProvider]. The `Future` is memoised so subsequent
/// reads complete synchronously after the first await. Idempotent on
/// the plugin side (a second `init` is a no-op).
Future<void>? _justAudioBackgroundInit;
Future<void> _ensureJustAudioBackground() {
  return _justAudioBackgroundInit ??= JustAudioBackground.init(
    androidNotificationChannelId: 'com.i99dev.ilink.radio',
    androidNotificationChannelName: 'Radio playback',
    androidNotificationOngoing: true,
  );
}

/// The player. `Provider.autoDispose<RadioPlayer>` so the underlying
/// `AudioPlayer` + native MediaSession aren't held when the user
/// never opens radio. The accepted trade-off: a small first-tap
/// penalty when re-opening radio after the screen has been off the
/// stack long enough for Riverpod to dispose the provider — better
/// than holding a native audio resource for users who don't use
/// radio at all.
///
/// On first read, kicks [_ensureJustAudioBackground] fire-and-forget
/// so the MediaSession host is ready before the controller's first
/// `setUrl`. JustAudioRadioPlayer's ctor only allocates a Dart-side
/// controller; the platform-channel AudioPlayer initialises lazily
/// inside `setUrl`, so the future resolves before any actual playback.
///
/// `RadioController` owns the player's `dispose()` call in its own
/// `onDispose`, so the audio resource is released through the controller
/// path.
///
/// NOT `autoDispose`. `RadioController.build` takes the player with
/// `ref.read`, which creates no subscription — under `autoDispose` this
/// provider therefore had zero listeners and was torn down immediately
/// after the controller grabbed it. The controller kept the orphaned
/// player, whose `streamingEnabled` closure below is guarded on
/// `ref.mounted`; once this ref was unmounted that guard returned false
/// forever, so every `play()` threw `ServiceDisabled` before emitting any
/// state and `RadioController._run` swallowed it — every station tap was a
/// silent no-op. The `ref.listen` revocation hook below died with it too.
/// The controller owns this player's lifetime, so it must outlive its own
/// creation frame.
final radioPlayerProvider = Provider<RadioPlayer>((ref) {
  unawaited(_ensureJustAudioBackground());
  final player = JustAudioRadioPlayer(
    streamingEnabled: () =>
        ref.mounted &&
        ref.read(serviceEnabledProvider(OptionalService.streaming)),
  );
  ref.listen(optionalServicesProvider, (_, next) {
    if (!(next.value?.contains(OptionalService.streaming) ?? false) &&
        !isLocalMedia(player.current.station?.streamUrl ?? '')) {
      unawaited(player.stop().catchError((Object _) {}));
    }
  });
  return player;
});

final radioFavoritesStoreProvider = Provider<RadioFavoritesStore>((ref) {
  return RadioFavoritesStore(ref.watch(sharedPreferencesProvider));
});

/// "I'm about to start playback" signal — bumped synchronously at the
/// top of every RadioController play method, before the just_audio
/// buffer call. The voice-playback coordinator listens to this so the
/// assistant gets cut off the instant a play tool is invoked, not when
/// the audio decode finishes (which can be 100-500 ms later — long
/// enough for the AI's TTS to start "playing X for you" first).
///
/// The value itself is an opaque counter — observers care about
/// changes, not the number. Resetting on dispose isn't necessary
/// because the assistant is the only consumer and it idempotently
/// transitions to idle on stop.
class PlaybackIntentNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Bump the counter — anyone listening will fire their reaction.
  void signalStarting() => state = state + 1;
}

final playbackIntentProvider = NotifierProvider<PlaybackIntentNotifier, int>(
  PlaybackIntentNotifier.new,
);

/// The main controller.
final radioControllerProvider = NotifierProvider<RadioController, RadioState>(
  RadioController.new,
);

/// Version counter bumped every time the favourites list mutates
/// (add / remove / toggle). Observers subscribe to the counter, not
/// the underlying [RadioFavoritesStore] blob, because the store is a
/// plain SharedPreferences-backed object with no change stream of its
/// own. Same pattern as [playbackIntentProvider] — opaque int, only
/// the transition matters.
///
/// Without this signal, widgets that snapshot favourites at mount time
/// (favourites-row pill strip, station-tile heart icon) stay stuck on
/// their initial state — favouriting a station mutates prefs but emits
/// no `RadioState` change for them to ride on.
class FavoritesVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void signalChanged() => state = state + 1;
}

final favoritesVersionProvider =
    NotifierProvider<FavoritesVersionNotifier, int>(
      FavoritesVersionNotifier.new,
    );

/// The fleet default region the Radio page lands on when the user hasn't
/// picked a playlist yet — matched against the curated catalogue's facet
/// labels (so "arabic" resolves the "Language: Arabic" playlist). Changing
/// this one constant re-homes every fresh install.
const String kRadioDefaultRegionQuery = 'arabic';

/// Persisted "default curated playlist" id for the Radio page. Fresh install
/// = null → the page resolves [kRadioDefaultRegionQuery] (Arabic) so it's
/// never empty on open. When the user picks a different playlist it's saved
/// here, so their choice sticks across launches — mirrors the TV
/// country-order preference ([tvCountryOrderProvider]).
class RadioDefaultPlaylistNotifier extends Notifier<String?> {
  static const _key = 'radio.default_playlist.v1';

  @override
  String? build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  /// Remember [entryId] (a curated index entry id) as the user's default.
  Future<void> set(String entryId) async {
    if (entryId.isEmpty || state == entryId) return;
    state = entryId;
    await ref.read(sharedPreferencesProvider).setString(_key, entryId);
  }
}

final radioDefaultPlaylistProvider =
    NotifierProvider<RadioDefaultPlaylistNotifier, String?>(
      RadioDefaultPlaylistNotifier.new,
    );

/// Resolved list of the user's favourited stations. Auto-refetches on
/// every [favoritesVersionProvider] bump, so any widget that watches
/// it stays in sync with add/remove/toggle without manual wiring.
///
/// `autoDispose` so the Future is torn down when no screen is
/// rendering favourites — the next mount starts from a fresh fetch
/// rather than a stale cache from a prior session.
final favoriteStationsProvider = FutureProvider.autoDispose<List<Station>>((
  ref,
) {
  ref.watch(favoritesVersionProvider);
  return ref.read(radioControllerProvider.notifier).favorites();
});

/// Version counter for the user-imported playlists set. Bumped by
/// `UserPlaylistController` on add/remove/refresh. Same opaque-counter
/// pattern as [favoritesVersionProvider]: observers (incl.
/// [RadioController]'s voice index, the My Playlists sheet) re-query
/// the store on each tick. The Notifier is declared here so callers can
/// `ref.listen` without depending on Phase 4's controller file.
class UserPlaylistsVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void signalChanged() => state = state + 1;
}

final userPlaylistsVersionProvider =
    NotifierProvider<UserPlaylistsVersionNotifier, int>(
      UserPlaylistsVersionNotifier.new,
    );

/// App-support directory holding the user-imported playlist JSON files.
/// Overridden in `main()` with the durable path
/// (`<appSupport>/user_playlists`). The default is an ephemeral temp
/// dir so tests and dev tooling get a working — if non-persistent —
/// store without having to wire path_provider.
final userPlaylistDirProvider = Provider<Directory>((_) {
  return Directory.systemTemp.createTempSync('ilink_user_playlists');
});

/// File-backed user-playlist store. Sync reads; writes async-persist.
final userPlaylistStoreProvider = Provider<UserPlaylistStore>((ref) {
  return FileUserPlaylistStore(ref.watch(userPlaylistDirProvider));
});

/// Importer for file + URL ingestion. Shares the cdn-purpose Dio with
/// the rest of the app (HTTP/2 pool, gzip, no backend auth) for
/// `importFromUrl`.
final userPlaylistImporterProvider = Provider<UserPlaylistImporter>((ref) {
  return UserPlaylistImporter(dio: ref.watch(dioProvider(DioPurpose.cdn)));
});

/// Command surface for adding/removing/refreshing user playlists.
final userPlaylistControllerProvider =
    NotifierProvider<UserPlaylistController, int>(UserPlaylistController.new);

/// Resolves when the file-backed store finishes its async disk
/// hydration. [userPlaylistsProvider] watches this so a cold boot
/// surfaces already-persisted playlists the moment they load — the
/// store reads JSON off disk asynchronously in its constructor, so a
/// synchronous `getAll()` issued before hydration completes returns an
/// empty list. Without this dependency that empty read would stick
/// until the next mutation bumped [userPlaylistsVersionProvider],
/// which is the "My Playlists is empty after reopening the car" bug.
final userPlaylistsHydratedProvider = FutureProvider<void>(
  (ref) => ref.watch(userPlaylistStoreProvider).ready,
);

/// Read-side view: the user's imported playlists, sorted most-recent
/// first. Watches [userPlaylistsVersionProvider] so add/remove/refresh
/// triggers a rebuild, and [userPlaylistsHydratedProvider] so the
/// initial cold-boot disk load surfaces without a mutation.
final userPlaylistsProvider = Provider<List<UserPlaylist>>((ref) {
  ref.watch(userPlaylistsVersionProvider);
  ref.watch(userPlaylistsHydratedProvider);
  return ref.watch(userPlaylistStoreProvider).getAll();
});

/// One-shot signal from the deep-link "Open with iLINK" path to the
/// radio screen: the id of a freshly-imported (or refreshed) playlist
/// that the screen should auto-select on its next build.
///
/// Set by `M3uPlaylistLinkHandler.open()` after a successful import;
/// the radio screen reads + clears it. A `Notifier<String?>` rather
/// than a plain provider so observers can react to transitions (not
/// just the value) and the handler can be tested without a UI.
class PendingUserPlaylistNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Stake the next radio-screen mount on opening this playlist.
  void claim(String id) => state = id;

  /// Called by the radio screen once the claim has been honoured.
  void clear() => state = null;
}

final pendingUserPlaylistProvider =
    NotifierProvider<PendingUserPlaylistNotifier, String?>(
      PendingUserPlaylistNotifier.new,
    );

// --- Curated (m3u-rest-api) layer ----------------------------------------

/// HTTP client for the m3u-rest-api JSON catalogue. Routes through the
/// shared [catalogueHttpProvider] (cdn Dio + license-token attach for the
/// gate host).
final curatedApiProvider = Provider<CuratedPlaylistApi>((ref) {
  return CuratedPlaylistApi(http: ref.watch(catalogueHttpProvider));
});

/// Persist-once cache for curated content (index + per-playlist
/// payloads). SharedPreferences-backed; payloads are small enough.
final curatedCacheProvider = Provider<CuratedCache>((ref) {
  return CuratedCache(ref.watch(sharedPreferencesProvider));
});

/// Orchestrator. Cache-first reads; explicit refresh wipes cache +
/// bumps state so [curatedIndexProvider] re-fetches.
final curatedPlaylistsControllerProvider =
    NotifierProvider<CuratedPlaylistsController, int>(
      CuratedPlaylistsController.new,
    );

/// Read-side view for the picker. Watches the controller's op counter
/// so a refresh re-runs the future. Per the persist-once contract the
/// future returns the cached value if present and hits the network
/// only on first run / post-refresh.
final curatedIndexProvider = FutureProvider<CuratedIndex>((ref) {
  ref.watch(curatedPlaylistsControllerProvider);
  return ref.read(curatedPlaylistsControllerProvider.notifier).getIndex();
});

/// The curated index bucketed by [RadioFacet], computed once per index value
/// and memoised by Riverpod. Centralises the facet grouping so the picker (and
/// any future browse-by-facet surface) reads ready-made groups instead of
/// re-scanning 400+ entries on every facet switch / keystroke. Empty while the
/// index is loading or errored — the picker shows the index's own state then.
final curatedFacetGroupsProvider = Provider<List<FacetGroup>>((ref) {
  return ref
      .watch(curatedIndexProvider)
      .maybeWhen(data: (idx) => idx.facetGroups(), orElse: () => const []);
});
