import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../domain/station.dart';
import '../domain/user_playlist.dart';
import 'content_uri_reader.dart';
import 'm3u_parser.dart';

/// Bodies larger than this are parsed on a background isolate so a big
/// user-imported list (IPTV-shaped lists run to tens of thousands of
/// entries) never janks the UI isolate. Small lists parse synchronously
/// to avoid the isolate-spawn overhead.
const int kIsolateParseThreshold = 48 * 1024;

/// Thrown when an import yields no playable stations. The UI displays
/// the message verbatim to the user, so phrasing should be operator-
/// friendly (`No playable stations in 'NAME'`).
class UserPlaylistImportException implements Exception {
  const UserPlaylistImportException(this.message);
  final String message;

  @override
  String toString() => 'UserPlaylistImportException: $message';
}

/// Two-mode import + refresh path for user-supplied playlists. All
/// ingestion goes through this one class — file picker, URL paste, and
/// refresh-of-existing — so validation, isolate-offload, and error
/// shape stay consistent.
///
/// The parser is injectable for tests; production uses
/// [parseM3uMaybeIsolate] which hops to a background isolate above
/// [kIsolateParseThreshold].
class UserPlaylistImporter {
  UserPlaylistImporter({
    required Dio dio,
    ContentUriReader? contentUriReader,
    Future<List<Station>> Function(String body)? parser,
  }) : _dio = dio,
       _contentUri = contentUriReader ?? ContentUriReader(),
       _parse = parser ?? parseM3uMaybeIsolate;

  final Dio _dio;
  final ContentUriReader _contentUri;
  final Future<List<Station>> Function(String body) _parse;

  /// Read a `.m3u` / `.m3u8` from local storage and materialise it.
  /// [name] is the user-given label shown in the picker; the resolved
  /// file path is persisted so a future refresh can re-read it.
  Future<UserPlaylist> importFromFile(File file, {required String name}) async {
    if (!await file.exists()) {
      throw UserPlaylistImportException('File not found: ${file.path}');
    }
    final body = await file.readAsString();
    return _materialise(body, name, UserPlaylistFileSource(file.path));
  }

  /// GET a remote `.m3u` / `.m3u8` and materialise it. The URL is
  /// persisted so a future refresh can re-fetch. Uses the injected
  /// [Dio] (provider wires `DioPurpose.cdn` — shared HTTP/2 pool, gzip,
  /// no auth) and asks for plain text so Dio won't try to JSON-decode
  /// the response on the way back.
  Future<UserPlaylist> importFromUrl(
    String url, {
    required String name,
    CancelToken? cancelToken,
  }) async {
    final body = await _fetch(url, cancelToken: cancelToken);
    return _materialise(body, name, UserPlaylistUrlSource(url));
  }

  /// Scheme-dispatching ingestion entry — the single funnel for
  /// "Open with iLINK" intents and any future URI-driven import.
  ///
  ///   * `file://`        → [importFromFile]
  ///   * `content://`     → read via [ContentUriReader] (SAF-aware)
  ///                        and persist with a [UserPlaylistFileSource]
  ///                        recording the original URI string. Refresh
  ///                        later may fail if the temporary URI grant
  ///                        wasn't taken persistable — surfaced as a
  ///                        clear error, not a silent stale import.
  ///   * `http`/`https://` → [importFromUrl]
  ///
  /// Throws [UserPlaylistImportException] for unsupported schemes so
  /// callers (the deep-link handler) can react with one branch.
  Future<UserPlaylist> importFromUri(
    Uri uri, {
    required String name,
    CancelToken? cancelToken,
  }) async {
    switch (uri.scheme) {
      case 'file':
        return importFromFile(File(uri.toFilePath()), name: name);
      case 'content':
        final String body;
        try {
          body = await _contentUri.readText(uri);
        } on ContentUriReadException catch (e) {
          throw UserPlaylistImportException(
            'Could not read shared file: ${e.message}',
          );
        }
        return _materialise(body, name, UserPlaylistFileSource(uri.toString()));
      case 'http':
      case 'https':
        return importFromUrl(
          uri.toString(),
          name: name,
          cancelToken: cancelToken,
        );
      default:
        throw UserPlaylistImportException(
          'Unsupported URI scheme "${uri.scheme}"',
        );
    }
  }

  /// Re-import an [existing] playlist against its original source.
  /// Returns a copy with refreshed stations and a fresh
  /// `lastRefreshedAt` stamp; the id and name are preserved so the
  /// store can overwrite in place.
  Future<UserPlaylist> refresh(
    UserPlaylist existing, {
    CancelToken? cancelToken,
  }) async {
    final source = existing.source;
    final body = switch (source) {
      UserPlaylistFileSource(:final path) => await _readFile(path),
      UserPlaylistUrlSource(:final url) => await _fetch(
        url,
        cancelToken: cancelToken,
      ),
    };
    final stations = await _parse(body);
    if (stations.isEmpty) {
      throw UserPlaylistImportException(
        'No playable stations in "${existing.name}" after refresh',
      );
    }
    return existing.withRefresh(at: DateTime.now(), stations: stations);
  }

  // --- internal -----------------------------------------------------------

  Future<UserPlaylist> _materialise(
    String body,
    String name,
    UserPlaylistSource source,
  ) async {
    final stations = await _parse(body);
    if (stations.isEmpty) {
      throw UserPlaylistImportException('No playable stations in "$name"');
    }
    final at = DateTime.now();
    return UserPlaylist(
      id: UserPlaylist.newId(name, at),
      name: name,
      source: source,
      importedAt: at,
      stations: stations,
    );
  }

  Future<String> _readFile(String path) async {
    // A content://… URI was persisted as the "path" when importing via
    // an ACTION_VIEW intent — route refresh through the ContentResolver
    // bridge. The URI permission is usually temporary, so a refresh
    // after a process death will surface a clear PERMISSION_DENIED.
    if (path.startsWith('content://')) {
      try {
        return await _contentUri.readText(Uri.parse(path));
      } on ContentUriReadException catch (e) {
        throw UserPlaylistImportException(
          'Could not re-read shared file: ${e.message}',
        );
      }
    }
    final f = File(path);
    if (!await f.exists()) {
      throw UserPlaylistImportException('File no longer exists: $path');
    }
    return f.readAsString();
  }

  Future<String> _fetch(String url, {CancelToken? cancelToken}) async {
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {'Accept': 'text/plain, application/x-mpegurl, */*'},
        ),
      );
      return res.data ?? '';
    } on DioException catch (e) {
      throw UserPlaylistImportException(
        'Fetch failed (${e.response?.statusCode ?? e.type.name}): $url',
      );
    }
  }
}

/// Parses M3U text, hopping to a background isolate above
/// [kIsolateParseThreshold] so a multi-MB import doesn't jank the UI.
/// Top-level so `compute()` can call it across isolates.
Future<List<Station>> parseM3uMaybeIsolate(String body) {
  if (body.length > kIsolateParseThreshold) {
    return compute(parseM3uIsolate, body);
  }
  return SynchronousFuture(parseM3u(body));
}
