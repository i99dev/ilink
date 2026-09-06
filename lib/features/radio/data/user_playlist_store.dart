import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/user_playlist.dart';

/// Storage seam for user-imported playlists. Phase 4's
/// `UserPlaylistController` depends on this interface so tests can use
/// an in-memory fake without touching the filesystem.
///
/// Reads are synchronous on purpose: the controller, the radio screen,
/// and the My Playlists sheet all expect immediate access to the
/// hydrated set. Implementations must keep an in-memory mirror and
/// persist asynchronously on writes.
abstract interface class UserPlaylistStore {
  /// Resolves once the on-disk state has been loaded into memory.
  /// Production callers rarely need to wait; tests await it for
  /// deterministic ordering.
  Future<void> get ready;

  /// All persisted playlists, ordered most-recently-imported first.
  List<UserPlaylist> getAll();

  UserPlaylist? getById(String id);

  /// Add or replace a playlist by id. Idempotent.
  Future<void> save(UserPlaylist playlist);

  /// Remove a playlist by id. No-op when absent.
  Future<void> remove(String id);
}

/// Filesystem-backed [UserPlaylistStore]: one JSON file per playlist
/// under [dir], indexed in memory.
///
/// Design mirrors `FilePlaylistCache` (atomic temp+rename writes, lazy
/// hydrate, sync reads) but without TTL — user data persists until the
/// user removes it.
class FileUserPlaylistStore implements UserPlaylistStore {
  FileUserPlaylistStore(this._dir) {
    _hydration = _hydrate();
  }

  final Directory _dir;
  final Map<String, UserPlaylist> _mem = {};
  late final Future<void> _hydration;

  @override
  Future<void> get ready => _hydration;

  @override
  List<UserPlaylist> getAll() {
    final out = _mem.values.toList()
      ..sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return List<UserPlaylist>.unmodifiable(out);
  }

  @override
  UserPlaylist? getById(String id) => _mem[id];

  @override
  Future<void> save(UserPlaylist playlist) async {
    _mem[playlist.id] = playlist;
    await _persist(playlist);
  }

  @override
  Future<void> remove(String id) async {
    _mem.remove(id);
    final f = _fileFor(id);
    if (await f.exists()) await f.delete();
  }

  // --- internal -----------------------------------------------------------

  Future<void> _hydrate() async {
    try {
      if (!await _dir.exists()) return;
      await for (final e in _dir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final json = jsonDecode(await e.readAsString());
          if (json is! Map<String, dynamic>) continue;
          final pl = UserPlaylist.fromJson(json);
          // Live writes during hydration win — same rule as
          // FilePlaylistCache so a fast save→reopen never loses data.
          _mem.putIfAbsent(pl.id, () => pl);
        } catch (_) {
          // Corrupt entry — ignore; a future save replaces it cleanly.
        }
      }
    } catch (_) {
      // Whole-dir scan failed (perms, race) — start cold, not crashed.
    }
  }

  Future<void> _persist(UserPlaylist playlist) async {
    try {
      if (!await _dir.exists()) await _dir.create(recursive: true);
      final f = _fileFor(playlist.id);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(playlist.toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // Persistence is best-effort; the in-memory entry still serves
      // this session. A failed disk write must never break playback.
    }
  }

  File _fileFor(String id) => File('${_dir.path}/$id.json');
}
