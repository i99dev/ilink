import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/curated_playlist_api.dart';
import 'package:ilink/features/radio/domain/curated_playlist.dart';
import 'package:ilink/features/radio/domain/station.dart';
import 'package:ilink/kernel/playlists/catalogue_http.dart';

/// Dependency-free fake adapter — routes by URL.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions o) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

CuratedPlaylistApi _api(_Adapter a) => CuratedPlaylistApi(
  baseUrl: _baseUrl,
  http: CatalogueHttp(dio: Dio()..httpClientAdapter = a),
);

// The test pins its own base so the URL assertions stay stable, decoupled
// from the production default.
const _baseUrl = 'https://content.i99dash.app/radio';

void main() {
  group('fetchIndex', () {
    test('parses the index.json shape into CuratedIndex', () async {
      final a = _Adapter((o) {
        expect(o.uri.toString(), '$_baseUrl/api/index.json');
        return _json({
          'generatedAt': '2026-02-01T17:48:10.789Z',
          'totalPlaylists': 2,
          'playlists': [
            {
              'name': 'Arabic',
              'url': 'api/playlists/arabic.json',
              'count': 1361,
            },
            {'name': 'Jazz', 'url': 'api/playlists/jazz.json', 'count': 215},
          ],
        }, 200);
      });
      final idx = await _api(a).fetchIndex();
      expect(idx.entries, hasLength(2));
      expect(idx.entries.first.name, 'Arabic');
      expect(idx.entries.first.id, 'arabic');
      expect(idx.entries.first.count, 1361);
      expect(idx.entries.first.urlPath, 'api/playlists/arabic.json');
    });

    test('drops entries missing name or url', () async {
      final a = _Adapter(
        (_) => _json({
          'generatedAt': 'x',
          'playlists': [
            {'name': 'OK', 'url': 'api/playlists/ok.json', 'count': 1},
            {'name': '', 'url': 'api/playlists/blank.json'},
            {'name': 'NoUrl'},
          ],
        }, 200),
      );
      final idx = await _api(a).fetchIndex();
      expect(idx.entries.map((e) => e.name), ['OK']);
    });

    test('http error → CuratedFetchException', () async {
      final a = _Adapter((_) => _json({}, 503));
      await expectLater(
        _api(a).fetchIndex(),
        throwsA(isA<CuratedFetchException>()),
      );
    });

    test(
      'non-object payload → CuratedFetchException(MALFORMED_INDEX)',
      () async {
        final a = _Adapter((_) => _json(['not', 'an', 'object'], 200));
        await expectLater(
          _api(a).fetchIndex(),
          throwsA(
            predicate(
              (e) => e is CuratedFetchException && e.code == 'MALFORMED_INDEX',
            ),
          ),
        );
      },
    );
  });

  group('fetchPlaylist', () {
    const entry = CuratedIndexEntry(
      id: 'arabic',
      name: 'Arabic',
      count: 3,
      urlPath: 'api/playlists/arabic.json',
    );

    test('parses items into Stations with sha1 ids + isHls detection', () async {
      final a = _Adapter((o) {
        expect(o.uri.toString(), '$_baseUrl/api/playlists/arabic.json');
        return _json({
          'name': 'Arabic',
          'sourceFile': 'playlists/Arabic.m3u',
          'count': 3,
          'generatedAt': '2026-02-01T17:48:10.789Z',
          'items': [
            {
              'name': 'راديو الناس',
              'url':
                  'https://cdna.streamgates.net/RadioNas/Live-Audio/icecast.audio',
            },
            {'name': 'HLS Stream', 'url': 'https://h/live/index.m3u8'},
            {'name': 'Plain', 'url': 'http://h/stream'},
          ],
        }, 200);
      });
      final pl = await _api(a).fetchPlaylist(entry);
      expect(pl.id, 'arabic');
      expect(pl.entryCount, 3);
      expect(pl.stations[0].name, 'راديو الناس');
      expect(pl.stations[1].isHls, isTrue);
      expect(pl.stations[2].streamUrl, 'http://h/stream');
      // sha1 id is deterministic over the URL
      expect(pl.stations[0].id, isNotEmpty);
    });

    test(
      'deduplicates by URL hash; skips blank-name and non-http items',
      () async {
        final a = _Adapter(
          (_) => _json({
            'name': 'Mixed',
            'items': [
              {'name': 'A', 'url': 'http://h/x'},
              {'name': 'Dup', 'url': 'http://h/x'}, // same URL → deduped
              {'name': '', 'url': 'http://h/y'}, // blank name → skipped
              {'name': 'Rel', 'url': '../path'}, // non-http → skipped
              {'name': 'B', 'url': 'http://h/z'},
            ],
          }, 200),
        );
        final pl = await _api(a).fetchPlaylist(entry);
        expect(pl.stations.map((s) => s.name), ['A', 'B']);
      },
    );

    test('cap enforced — large items list truncated', () async {
      final manyItems = [
        for (var i = 0; i < 50; i++) {'name': 'S$i', 'url': 'http://h/$i'},
      ];
      final a = _Adapter(
        (_) => _json({'name': 'Big', 'items': manyItems}, 200),
      );
      final pl = await _api(a).fetchPlaylist(entry, cap: 10);
      expect(pl.stations, hasLength(10));
      expect(pl.stations.first.name, 'S0');
      expect(pl.stations.last.name, 'S9');
    });

    test('404 → CuratedFetchException(NOT_FOUND)', () async {
      final a = _Adapter((_) => _json({}, 404));
      await expectLater(
        _api(a).fetchPlaylist(entry),
        throwsA(
          predicate((e) => e is CuratedFetchException && e.code == 'NOT_FOUND'),
        ),
      );
    });

    test('empty urlPath → CuratedFetchException(INVALID_ENTRY)', () async {
      final a = _Adapter((_) => _json({}, 200));
      await expectLater(
        _api(a).fetchPlaylist(
          const CuratedIndexEntry(id: 'x', name: 'x', count: 0, urlPath: ''),
        ),
        throwsA(
          predicate(
            (e) => e is CuratedFetchException && e.code == 'INVALID_ENTRY',
          ),
        ),
      );
    });
  });

  group('CuratedPlaylist JSON round-trip (cache shape)', () {
    test('serialise + restore preserves stations', () {
      const pl = CuratedPlaylist(
        id: 'arabic',
        name: 'Arabic',
        stations: [
          Station(
            id: 'abc',
            sourceUuid: '',
            name: 'X',
            streamUrl: 'https://h/x',
          ),
        ],
      );
      final restored = CuratedPlaylist.fromJson(
        jsonDecode(jsonEncode(pl.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, 'arabic');
      expect(restored.stations.single.name, 'X');
    });
  });
}
