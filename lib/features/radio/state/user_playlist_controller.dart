import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../_car_domain/command/command_outcome.dart';
import '../data/user_playlist_importer.dart';
import '../data/user_playlist_store.dart';
import '../domain/user_playlist.dart';
import '../providers.dart';
import '../radio_controller.dart';

/// Command surface for user-imported playlists.
///
/// Every mutation (add / remove / refresh) goes through here so:
///   * The new/updated playlist's stations are indexed into the
///     [RadioController]'s voice-search map immediately.
///   * [userPlaylistsVersionProvider] is bumped, which wakes the My
///     Playlists sheet AND triggers the radio controller's
///     `_rebuildIndex` listener (covers cold-boot indexing of
///     already-persisted playlists too).
///
/// Methods return [CommandOutcome] — same shape as [RadioController] —
/// so the UI surface and any future voice-tool entrypoint can both
/// inspect `outcome.ok`.
///
/// The notifier state is an opaque op counter, not the playlist list:
/// the list lives in the store and is read by UI via
/// [userPlaylistsProvider]. Splitting state from the command surface
/// keeps the controller tiny and avoids re-rendering everywhere on
/// every transient operation.
class UserPlaylistController extends Notifier<int> {
  late UserPlaylistStore _store;
  late UserPlaylistImporter _importer;

  @override
  int build() {
    _store = ref.read(userPlaylistStoreProvider);
    _importer = ref.read(userPlaylistImporterProvider);
    return 0;
  }

  /// Import from the file picker. Dedupes by source: re-importing the
  /// same path refreshes the existing playlist in place rather than
  /// creating a second entry — matches what the user expects when they
  /// load the same `.m3u` again (the old behaviour minted a fresh id
  /// per import, so re-loading produced visible duplicates).
  Future<CommandOutcome> addFromFile(File file, {required String name}) =>
      _run('addFromFile($name)', () {
        final source = UserPlaylistFileSource(file.path);
        return _saveOrRefresh(
          _findByStoredSource(source),
          () => _importer.importFromFile(file, name: name),
        );
      });

  /// Import from a pasted URL. Dedupes by source — see [addFromFile].
  Future<CommandOutcome> addFromUrl(String url, {required String name}) =>
      _run('addFromUrl($name)', () {
        final source = UserPlaylistUrlSource(url);
        return _saveOrRefresh(
          _findByStoredSource(source),
          () => _importer.importFromUrl(url, name: name),
        );
      });

  /// Scheme-dispatching add — the single funnel used by the "Open with
  /// iLINK" deep-link handler. Dedupes by source: re-importing the
  /// same file:/content:/URL refreshes the existing playlist in place
  /// instead of creating a duplicate.
  Future<CommandOutcome> addFromUri(Uri uri, {required String name}) =>
      _run('addFromUri($uri)', () {
        return _saveOrRefresh(
          _findBySource(uri),
          () => _importer.importFromUri(uri, name: name),
        );
      });

  /// Shared save path for all three import entry points. When
  /// [existing] is non-null (a stored playlist already has this
  /// source) the playlist is refreshed in place — the existing id is
  /// preserved so any UI selection pointing at it survives — instead
  /// of a duplicate being created. Otherwise [import] runs and the new
  /// playlist is saved. Either way the result is indexed into voice
  /// search and observers are signalled via [_indexAndBump].
  Future<Object?> _saveOrRefresh(
    UserPlaylist? existing,
    Future<UserPlaylist> Function() import,
  ) async {
    if (existing != null) {
      final refreshed = await _importer.refresh(existing);
      await _store.save(refreshed);
      _indexAndBump(refreshed);
      return {
        'id': refreshed.id,
        'count': refreshed.entryCount,
        'deduped': true,
      };
    }
    final pl = await import();
    await _store.save(pl);
    _indexAndBump(pl);
    return {'id': pl.id, 'count': pl.entryCount};
  }

  /// Find a stored playlist whose persisted source equals [candidate]
  /// (value equality on the sealed source — file path or URL). Used by
  /// the file-picker / URL-paste paths to dedupe the same way the
  /// deep-link [_findBySource] path does.
  UserPlaylist? _findByStoredSource(UserPlaylistSource candidate) {
    for (final pl in _store.getAll()) {
      if (pl.source == candidate) return pl;
    }
    return null;
  }

  /// Find a stored playlist whose source matches [uri], for dedupe.
  /// Exact-match on the persisted identifier (file path or URL); a
  /// `file://...` URI also matches a raw filesystem-path FileSource
  /// because file-picker imports record the bare path while deep-link
  /// imports record the URI string.
  UserPlaylist? _findBySource(Uri uri) {
    final key = uri.toString();
    for (final pl in _store.getAll()) {
      final src = pl.source;
      final stored = switch (src) {
        UserPlaylistFileSource(:final path) => path,
        UserPlaylistUrlSource(:final url) => url,
      };
      if (stored == key) return pl;
      if (uri.scheme == 'file' && src is UserPlaylistFileSource) {
        try {
          if (uri.toFilePath() == src.path) return pl;
        } catch (_) {
          // Non-convertible URI — fall through to no-match.
        }
      }
    }
    return null;
  }

  Future<CommandOutcome> remove(String id) => _run('remove($id)', () async {
    await _store.remove(id);
    ref.read(userPlaylistsVersionProvider.notifier).signalChanged();
    return {'id': id};
  });

  Future<CommandOutcome> refresh(String id) => _run('refresh($id)', () async {
    final existing = _store.getById(id);
    if (existing == null) {
      throw StateError('unknown playlist "$id"');
    }
    final refreshed = await _importer.refresh(existing);
    await _store.save(refreshed);
    _indexAndBump(refreshed);
    return {'id': refreshed.id, 'count': refreshed.entryCount};
  });

  void _indexAndBump(UserPlaylist pl) {
    ref.read(radioControllerProvider.notifier).indexStations(pl.stations);
    ref.read(userPlaylistsVersionProvider.notifier).signalChanged();
    state = state + 1;
  }

  Future<CommandOutcome> _run(
    String label,
    Future<Object?> Function() fn,
  ) async {
    try {
      final out = await fn();
      if (out is Map<String, dynamic>) return CommandOutcome.success(out);
      return CommandOutcome.success();
    } catch (e) {
      return CommandOutcome.failure('$label failed: $e');
    }
  }
}
