import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import '../../../kernel/playlists/catalogue_http.dart';
import '../domain/curated_playlist.dart';
import '../domain/station.dart';
import 'm3u_parser.dart' show kDefaultStationCap;
import 'station_identity.dart';

/// Surface for any platform-side failure fetching curated content —
/// surfaced to the picker UI as a SnackBar message. The codes mirror
/// the most useful Dio failure modes (network down, 404 missing
/// playlist, malformed JSON) so callers can react if they care.
class CuratedFetchException implements Exception {
  const CuratedFetchException(this.message, [this.code = 'UNKNOWN']);
  final String message;
  final String code;

  @override
  String toString() => 'CuratedFetchException($code): $message';
}

/// Bundled radio discovery with optional caller-selected remote catalogs.
class CuratedPlaylistApi {
  CuratedPlaylistApi({
    required CatalogueHttp http,
    String baseUrl = kCuratedBaseUrl,
  }) : _http = http,
       _baseUrl = _normaliseBase(baseUrl);

  /// Empty default selects standalone catalog behavior.
  static const String kCuratedBaseUrl = '';

  final CatalogueHttp _http;
  final String _baseUrl;
  Future<Map<String, dynamic>>? _bundled;

  Future<CuratedIndex> fetchIndex({CancelToken? cancelToken}) async {
    final json = await _fetchJson(
      '$_baseUrl/api/index.json',
      cancelToken: cancelToken,
      label: 'index',
    );
    if (json is! Map<String, dynamic>) {
      throw const CuratedFetchException(
        'Index payload is not a JSON object',
        'MALFORMED_INDEX',
      );
    }
    return CuratedIndex.fromJson(json);
  }

  /// Fetches a single playlist and materialises it into our Station
  /// model. Honours [cap] (defaults to [kDefaultStationCap]) so a
  /// huge curated bucket (some are 7-9k entries) doesn't blow the
  /// heap; the parser-side cap is the canonical scalability bound.
  Future<CuratedPlaylist> fetchPlaylist(
    CuratedIndexEntry entry, {
    int cap = kDefaultStationCap,
    CancelToken? cancelToken,
  }) async {
    if (entry.urlPath.isEmpty) {
      throw const CuratedFetchException(
        'Entry has no urlPath',
        'INVALID_ENTRY',
      );
    }
    final json = await _fetchJson(
      '$_baseUrl/${entry.urlPath}',
      cancelToken: cancelToken,
      label: entry.name,
    );
    if (json is! Map<String, dynamic>) {
      throw const CuratedFetchException(
        'Playlist payload is not a JSON object',
        'MALFORMED_PLAYLIST',
      );
    }
    final items = (json['items'] as List?) ?? const [];
    final stations = <Station>[];
    final seen = <String>{};
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final name = (raw['name'] as String?)?.trim() ?? '';
      final url = (raw['url'] as String?)?.trim() ?? '';
      if (name.isEmpty || !_isHttpUrl(url)) continue;
      final id = StationIdentity.forStreamUrl(url);
      if (id.isEmpty || !seen.add(id)) continue;
      stations.add(
        Station(
          id: id,
          sourceUuid: '',
          name: name,
          streamUrl: url,
          isHls: url.contains('.m3u8'),
        ),
      );
      if (stations.length >= cap) break;
    }
    return CuratedPlaylist(
      id: entry.id,
      name: entry.name,
      stations: List<Station>.unmodifiable(stations),
    );
  }

  // --- internal -----------------------------------------------------------

  Future<dynamic> _fetchJson(
    String url, {
    CancelToken? cancelToken,
    required String label,
  }) async {
    if (_baseUrl.isEmpty) {
      final data = await (_bundled ??= rootBundle
          .loadString('assets/radio/catalog.json')
          .then((s) => jsonDecode(s) as Map<String, dynamic>));
      if (url.endsWith('/api/index.json')) return data['index'];
      final key = url.startsWith('/') ? url.substring(1) : url;
      final playlist = (data['playlists'] as Map)[key];
      if (playlist == null) {
        throw const CuratedFetchException(
          'This saved group has no bundled copy. Import a playlist to restore it.',
          'LOCAL_ONLY',
        );
      }
      return playlist;
    }
    try {
      // Explicit caller-selected catalog URL.
      return await _http.getJson(url, cancelToken: cancelToken);
    } on DioException catch (e) {
      throw CuratedFetchException(
        'Fetch failed for $label: ${e.response?.statusCode ?? e.type.name}',
        e.response?.statusCode == 404 ? 'NOT_FOUND' : 'NETWORK',
      );
    }
  }
}

/// Strip a trailing slash so we can always concatenate with a leading
/// `/api/...` path without doubling.
String _normaliseBase(String base) =>
    base.endsWith('/') ? base.substring(0, base.length - 1) : base;

bool _isHttpUrl(String s) =>
    s.startsWith('http://') || s.startsWith('https://');
