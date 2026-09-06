import 'package:dio/dio.dart';

/// Unauthenticated HTTP for public radio and TV catalogues.
class CatalogueHttp {
  CatalogueHttp({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Result of a conditional GET. [notModified] is true when the server
  /// answered `304` to our `If-None-Match` — [data] is then null and the
  /// caller should keep its cached copy. [etag] is the strong validator to
  /// persist for the next conditional fetch.
  ///
  /// Plain (non-conditional) callers can ignore everything but [data].
  static const int _statusNotModified = 304;

  /// GET public JSON from [url]. No account or token is required.
  /// When [etag] is supplied, sends `If-None-Match` and treats `304` as
  /// "not modified" instead of an error.
  ///
  /// Returns the decoded body on `200`, or [CatalogueNotModified] sentinel
  /// behaviour via [getConditional] for the conditional path. This plain
  /// variant throws [DioException] on failure (callers map it to their own
  /// typed exception, preserving their existing error contracts).
  Future<dynamic> getJson(String url, {CancelToken? cancelToken}) async {
    final res = await _dio.get<dynamic>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        headers: const {'Accept': 'application/json'},
      ),
    );
    return res.data;
  }

  /// Conditional GET. Pass the previously-stored [etag]; on `304` returns
  /// `(data: null, notModified: true, etag: <same>)` so the caller serves
  /// its cache. On `200` returns the fresh body + the new etag to persist.
  Future<CatalogueResponse> getConditional(
    String url, {
    String? etag,
    CancelToken? cancelToken,
  }) async {
    final res = await _dio.get<dynamic>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        headers: {
          'Accept': 'application/json',
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
        // 304 is a success for us, not a throw.
        validateStatus: (s) =>
            s != null && (s == 200 || s == _statusNotModified),
      ),
    );
    if (res.statusCode == _statusNotModified) {
      return CatalogueResponse(data: null, notModified: true, etag: etag);
    }
    return CatalogueResponse(
      data: res.data,
      notModified: false,
      etag: res.headers.value('etag') ?? etag,
    );
  }
}

/// A conditional-GET outcome — see [CatalogueHttp.getConditional].
class CatalogueResponse {
  const CatalogueResponse({
    required this.data,
    required this.notModified,
    required this.etag,
  });

  final dynamic data;
  final bool notModified;
  final String? etag;
}
