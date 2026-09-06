import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/data/content_uri_reader.dart';
import 'package:ilink/features/radio/data/m3u_parser.dart';
import 'package:ilink/features/radio/data/user_playlist_importer.dart';
import 'package:ilink/features/radio/domain/user_playlist.dart';

/// Dependency-free fake Dio adapter — routes by request URL.
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

ResponseBody _text(String body, int status, {String? contentType}) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [contentType ?? 'text/plain'],
      },
    );

UserPlaylistImporter _importer(_Adapter a, {ContentUriReader? reader}) =>
    UserPlaylistImporter(
      dio: Dio()..httpClientAdapter = a,
      contentUriReader: reader,
      // Synchronous parser keeps the unit test out of the isolate scheduler.
      parser: (b) async => parseM3u(b),
    );

/// Subclass-stub for ContentUriReader — keeps the channel field
/// (private) inherited untouched and just hijacks the public method.
class _StubReader extends ContentUriReader {
  _StubReader(this.responses);
  final Map<String, String> responses;
  @override
  Future<String> readText(Uri uri) async {
    final r = responses[uri.toString()];
    if (r == null) {
      throw const ContentUriReadException('NOT_FOUND', 'no stub for that uri');
    }
    return r;
  }
}

const _validM3u = '''
#EXTM3U
#EXTINF:-1, DW Arabic
https://dw.example/arabic
#EXTINF:-1, Radio X
http://x.example:8000/stream
''';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('upi_test_');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('importFromFile', () {
    test('reads, parses, and tags with a UserPlaylistFileSource', () async {
      final f = File('${dir.path}/arabic.m3u')..writeAsStringSync(_validM3u);
      final imp = _importer(_Adapter((_) => _text('', 200)));
      final pl = await imp.importFromFile(f, name: 'Arabic');

      expect(pl.name, 'Arabic');
      expect(pl.entryCount, 2);
      expect(pl.source, isA<UserPlaylistFileSource>());
      expect((pl.source as UserPlaylistFileSource).path, f.path);
      expect(pl.stations.first.name, 'DW Arabic');
    });

    test('empty parse → UserPlaylistImportException', () async {
      final f = File('${dir.path}/empty.m3u')..writeAsStringSync('not m3u');
      final imp = _importer(_Adapter((_) => _text('', 200)));
      expect(
        () => imp.importFromFile(f, name: 'Empty'),
        throwsA(isA<UserPlaylistImportException>()),
      );
    });

    test('missing file → UserPlaylistImportException', () async {
      final f = File('${dir.path}/missing.m3u');
      final imp = _importer(_Adapter((_) => _text('', 200)));
      await expectLater(
        imp.importFromFile(f, name: 'Missing'),
        throwsA(isA<UserPlaylistImportException>()),
      );
    });
  });

  group('importFromUrl', () {
    test(
      'fetches via Dio, parses, tags with a UserPlaylistUrlSource',
      () async {
        final a = _Adapter((o) {
          expect(o.uri.toString(), 'https://h/list.m3u');
          return _text(_validM3u, 200);
        });
        final pl = await _importer(
          a,
        ).importFromUrl('https://h/list.m3u', name: 'List');

        expect(pl.name, 'List');
        expect(pl.entryCount, 2);
        expect(pl.source, isA<UserPlaylistUrlSource>());
        expect((pl.source as UserPlaylistUrlSource).url, 'https://h/list.m3u');
      },
    );

    test('HTTP error → UserPlaylistImportException with status', () async {
      final a = _Adapter((_) => _text('', 404));
      await expectLater(
        _importer(a).importFromUrl('https://h/missing.m3u', name: 'X'),
        throwsA(
          predicate(
            (e) =>
                e is UserPlaylistImportException && e.message.contains('404'),
          ),
        ),
      );
    });

    test('empty body → UserPlaylistImportException', () async {
      final a = _Adapter((_) => _text('', 200));
      await expectLater(
        _importer(a).importFromUrl('https://h/empty.m3u', name: 'E'),
        throwsA(isA<UserPlaylistImportException>()),
      );
    });
  });

  group('importFromUri (scheme dispatch)', () {
    test('file:// delegates to importFromFile path', () async {
      final f = File('${dir.path}/local.m3u')..writeAsStringSync(_validM3u);
      final pl = await _importer(
        _Adapter((_) => _text('', 200)),
      ).importFromUri(f.uri, name: 'Local');
      expect(pl.entryCount, 2);
      expect(pl.source, isA<UserPlaylistFileSource>());
      // Path-separator can differ between f.path (native) and the value
      // Uri.toFilePath() emits when the URI was constructed from a
      // forward-slash string on Windows — assert the filename only,
      // which is the contract-relevant part regardless of platform.
      expect((pl.source as UserPlaylistFileSource).path, endsWith('local.m3u'));
    });

    test(
      'content:// goes through ContentUriReader and records the URI',
      () async {
        const contentUri = 'content://media/external/file/42';
        final stub = _StubReader({contentUri: _validM3u});
        final pl = await _importer(
          _Adapter((_) => _text('', 200)),
          reader: stub,
        ).importFromUri(Uri.parse(contentUri), name: 'Shared');
        expect(pl.entryCount, 2);
        expect(pl.source, isA<UserPlaylistFileSource>());
        expect((pl.source as UserPlaylistFileSource).path, contentUri);
      },
    );

    test(
      'content:// read failure surfaces as UserPlaylistImportException',
      () async {
        final stub = _StubReader(const {}); // any uri → NOT_FOUND
        await expectLater(
          _importer(
            _Adapter((_) => _text('', 200)),
            reader: stub,
          ).importFromUri(Uri.parse('content://x'), name: 'X'),
          throwsA(isA<UserPlaylistImportException>()),
        );
      },
    );

    test('https:// delegates to importFromUrl', () async {
      final a = _Adapter((o) {
        expect(o.uri.toString(), 'https://h/list.m3u');
        return _text(_validM3u, 200);
      });
      final pl = await _importer(
        a,
      ).importFromUri(Uri.parse('https://h/list.m3u'), name: 'List');
      expect(pl.entryCount, 2);
      expect(pl.source, isA<UserPlaylistUrlSource>());
    });

    test('http:// also works (cleartext radio metadata pages)', () async {
      final a = _Adapter((_) => _text(_validM3u, 200));
      final pl = await _importer(
        a,
      ).importFromUri(Uri.parse('http://h/list.m3u'), name: 'List');
      expect(pl.entryCount, 2);
    });

    test('unsupported scheme → UserPlaylistImportException', () async {
      await expectLater(
        _importer(
          _Adapter((_) => _text('', 200)),
        ).importFromUri(Uri.parse('mailto:x@y.z'), name: 'X'),
        throwsA(isA<UserPlaylistImportException>()),
      );
    });

    test(
      'refresh of a content://-sourced playlist re-reads via the bridge',
      () async {
        const contentUri = 'content://media/external/file/77';
        final stub = _StubReader({contentUri: _validM3u});
        final imp = _importer(_Adapter((_) => _text('', 200)), reader: stub);
        final v1 = await imp.importFromUri(
          Uri.parse(contentUri),
          name: 'Shared',
        );
        // Update the stub's response to simulate the source changing.
        stub.responses[contentUri] =
            '#EXTM3U\n#EXTINF:-1, Only\nhttp://h/only\n';
        final v2 = await imp.refresh(v1);
        expect(v2.entryCount, 1);
        expect(v2.stations.single.name, 'Only');
      },
    );
  });

  group('refresh', () {
    test('URL source: re-fetches and returns withRefresh', () async {
      // First fetch returns one station, second fetch returns three.
      var calls = 0;
      final a = _Adapter((_) {
        calls++;
        if (calls == 1) {
          return _text('#EXTM3U\n#EXTINF:-1, A\nhttp://h/a\n', 200);
        }
        return _text(_validM3u, 200);
      });
      final imp = _importer(a);
      final v1 = await imp.importFromUrl('https://h/list.m3u', name: 'List');
      expect(v1.entryCount, 1);

      final v2 = await imp.refresh(v1);
      expect(v2.id, v1.id, reason: 'id preserved across refresh');
      expect(v2.name, v1.name);
      expect(v2.entryCount, 2);
      expect(v2.lastRefreshedAt, isNotNull);
    });

    test('file source: re-reads the path', () async {
      final f = File('${dir.path}/list.m3u')..writeAsStringSync(_validM3u);
      final imp = _importer(_Adapter((_) => _text('', 200)));
      final v1 = await imp.importFromFile(f, name: 'List');

      f.writeAsStringSync('#EXTM3U\n#EXTINF:-1, Only\nhttp://h/only\n');
      final v2 = await imp.refresh(v1);
      expect(v2.entryCount, 1);
      expect(v2.stations.single.name, 'Only');
    });

    test('refresh of empty content throws', () async {
      final f = File('${dir.path}/list.m3u')..writeAsStringSync(_validM3u);
      final imp = _importer(_Adapter((_) => _text('', 200)));
      final v1 = await imp.importFromFile(f, name: 'List');
      f.writeAsStringSync(''); // wipe content
      await expectLater(
        imp.refresh(v1),
        throwsA(isA<UserPlaylistImportException>()),
      );
    });
  });
}
