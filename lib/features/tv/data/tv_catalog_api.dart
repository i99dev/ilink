import 'package:dio/dio.dart';

import '../../../kernel/playlists/catalogue_http.dart';
import '../../../kernel/playlists/m3u_parser.dart' show kDefaultEntryCap;
import '../domain/channel.dart';
import '../domain/tv_catalog.dart';

/// Any platform-side failure fetching catalogue content — surfaced to the UI
/// as a SnackBar. Codes mirror the useful Dio failure modes.
class TvCatalogException implements Exception {
  const TvCatalogException(this.message, [this.code = 'UNKNOWN']);
  final String message;
  final String code;

  @override
  String toString() => 'TvCatalogException($code): $message';
}

/// Optional caller-selected TV catalogs; saved groups and local imports work
/// without a hosted discovery service.
class TvCatalogApi {
  TvCatalogApi({required CatalogueHttp http, String baseUrl = kCatalogBaseUrl})
    : _http = http,
      _baseUrl = _normaliseBase(baseUrl);

  /// Empty default selects standalone catalog behavior.
  static const String kCatalogBaseUrl = '';

  final CatalogueHttp _http;
  final String _baseUrl;

  Future<TvCatalogIndex> fetchIndex({CancelToken? cancelToken}) async {
    if (_baseUrl.isEmpty) return TvCatalogIndex.fromJson({'groups': const []});
    final json = await _fetchJson(
      '$_baseUrl/index.json',
      cancelToken: cancelToken,
      label: 'index',
    );
    if (json is! Map<String, dynamic>) {
      throw const TvCatalogException(
        'Index payload is not a JSON object',
        'MALFORMED_INDEX',
      );
    }
    return TvCatalogIndex.fromJson(json);
  }

  /// Fetch a single group shard and materialise its channels. Honours [cap]
  /// (the parser-side scalability bound) and dedups by channel id.
  Future<TvChannelGroup> fetchGroup(
    TvCatalogGroup group, {
    int cap = kDefaultEntryCap,
    CancelToken? cancelToken,
  }) async {
    if (group.path.isEmpty) {
      throw const TvCatalogException('Group has no path', 'INVALID_GROUP');
    }
    final json = await _fetchJson(
      '$_baseUrl/${group.path}',
      cancelToken: cancelToken,
      label: group.name,
    );
    if (json is! Map<String, dynamic>) {
      throw const TvCatalogException(
        'Group payload is not a JSON object',
        'MALFORMED_GROUP',
      );
    }
    final items = (json['channels'] as List?) ?? const [];
    final channels = <Channel>[];
    final seen = <String>{};
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final ch = Channel.fromCatalogJson(raw);
      if (ch.id.isEmpty || ch.name.isEmpty || !seen.add(ch.id)) continue;
      channels.add(ch);
      if (channels.length >= cap) break;
    }
    return TvChannelGroup(
      id: group.id,
      name: group.name,
      channels: List<Channel>.unmodifiable(channels),
    );
  }

  // --- internal -----------------------------------------------------------

  Future<dynamic> _fetchJson(
    String url, {
    CancelToken? cancelToken,
    required String label,
  }) async {
    if (_baseUrl.isEmpty) {
      throw const TvCatalogException(
        'Import a playlist to add media. Hosted discovery has been retired.',
        'LOCAL_ONLY',
      );
    }
    try {
      // Explicit caller-selected catalog URL.
      return await _http.getJson(url, cancelToken: cancelToken);
    } on DioException catch (e) {
      throw TvCatalogException(
        'Fetch failed for $label: ${e.response?.statusCode ?? e.type.name}',
        e.response?.statusCode == 404 ? 'NOT_FOUND' : 'NETWORK',
      );
    }
  }
}

String _normaliseBase(String base) =>
    base.endsWith('/') ? base.substring(0, base.length - 1) : base;
