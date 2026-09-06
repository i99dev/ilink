import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/playlists/catalogue_http.dart';

/// Captures the outgoing RequestOptions so we can assert which headers were
/// sent, and returns a canned response.
class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.body = const {'ok': true}, this.etag});
  final int status;
  final Object body;
  final String? etag;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      status == 304 ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (etag != null) 'etag': [etag!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

CatalogueHttp _http(_Adapter a) =>
    CatalogueHttp(dio: Dio()..httpClientAdapter = a);

void main() {
  test('public catalogue requests never attach authentication', () async {
    final a = _Adapter();
    await _http(a).getJson('https://example.com/catalogue/index.json');
    expect(a.lastRequest!.headers.containsKey('Authorization'), isFalse);
    expect(a.lastRequest!.headers['Accept'], 'application/json');
  });

  group('CatalogueHttp conditional GET', () {
    test('sends If-None-Match and returns fresh data + etag on 200', () async {
      final a = _Adapter(status: 200, body: {'v': 1}, etag: '"abc"');
      final r = await _http(
        a,
      ).getConditional('https://example.com/radio/index.json', etag: '"old"');
      expect(a.lastRequest!.headers['If-None-Match'], '"old"');
      expect(r.notModified, isFalse);
      expect((r.data as Map)['v'], 1);
      expect(r.etag, '"abc"');
    });

    test('304 -> notModified, null data, keeps the prior etag', () async {
      final a = _Adapter(status: 304);
      final r = await _http(
        a,
      ).getConditional('https://example.com/radio/index.json', etag: '"keep"');
      expect(r.notModified, isTrue);
      expect(r.data, isNull);
      expect(r.etag, '"keep"');
    });
  });
}
