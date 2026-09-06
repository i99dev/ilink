import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/installed_mini_app_store.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';
import 'package:path/path.dart' as p;

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final r = respond(options);
    return r is Future<ResponseBody> ? await r : r;
  }

  @override
  void close({bool force = false}) {}
}

/// Build a tarball in-memory containing the given path → bytes pairs.
List<int> _makeTarGz(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.addFile(ArchiveFile(name, content.length, content));
  });
  final tar = TarEncoder().encode(archive);
  return const GZipEncoder().encode(tar);
}

ResponseBody _bodyOk(List<int> bytes) {
  return ResponseBody.fromBytes(
    bytes,
    200,
    headers: {
      'content-type': ['application/octet-stream'],
    },
  );
}

InstalledMiniAppStore _store(_ScriptedAdapter adapter, Directory tmp) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return InstalledMiniAppStore(dio: dio, appSupportDirFactory: () async => tmp);
}

MiniApp _miniApp({
  String id = 'demo-app',
  String version = '0.1.0',
  String url = 'https://cdn.example/bundles/demo-app/0.1.0/bundle.tar.gz',
  String? sha256Hex,
}) {
  return MiniApp(
    id: id,
    name: const {'en': 'Demo'},
    description: const {'en': 'Demo app'},
    icon: 'https://cdn.example/icon.png',
    url: 'https://cdn.example/$id/0.1.0/index.html',
    version: version,
    minHostVersion: '0.0.0',
    category: 'info',
    bundleUrl: url,
    bundleSha256:
        sha256Hex ??
        '0000000000000000000000000000000000000000000000000000000000000000',
    safeWhileDriving: false,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('miniapp_install_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('install: downloads, verifies, extracts to versioned dir', () async {
    final tarball = _makeTarGz({
      'index.html': '<h1>Hello</h1>'.codeUnits,
      'app.js': "console.log('hi')".codeUnits,
    });
    final hash = sha256.convert(tarball).toString();
    final adapter = _ScriptedAdapter((_) => _bodyOk(tarball));
    final store = _store(adapter, tmp);

    final app = _miniApp(sha256Hex: hash);
    await store.install(app, cancelToken: CancelToken());

    final indexPath = await store.indexHtmlPath('demo-app');
    expect(indexPath, isNotNull);
    expect(File(indexPath!).existsSync(), isTrue);
    expect(await File(indexPath).readAsString(), '<h1>Hello</h1>');
    expect(await store.installedVersion('demo-app'), '0.1.0');

    // Sibling asset is also extracted.
    expect(File(p.join(p.dirname(indexPath), 'app.js')).existsSync(), isTrue);
  });

  test(
    'install: SHA-256 mismatch throws checksumMismatch and rolls back',
    () async {
      final tarball = _makeTarGz({'index.html': '<h1>Hi</h1>'.codeUnits});
      // Wrong claimed hash — bytes are valid but don't match.
      final claimedWrong = 'a' * 64;
      final adapter = _ScriptedAdapter((_) => _bodyOk(tarball));
      final store = _store(adapter, tmp);

      final app = _miniApp(sha256Hex: claimedWrong);
      expect(
        () => store.install(app, cancelToken: CancelToken()),
        throwsA(
          isA<MiniAppInstallException>().having(
            (e) => e.reason,
            'reason',
            MiniAppInstallFailure.checksumMismatch,
          ),
        ),
      );

      // No version dir was promoted.
      expect(await store.installedVersion('demo-app'), isNull);
      expect(await store.indexHtmlPath('demo-app'), isNull);
    },
  );

  test(
    'install: bundle without index.html rejected as invalidBundle',
    () async {
      final tarball = _makeTarGz({
        // Forgot to include index.html — the WebView would 404 on launch.
        'app.js': 'console.log(1)'.codeUnits,
      });
      final hash = sha256.convert(tarball).toString();
      final adapter = _ScriptedAdapter((_) => _bodyOk(tarball));
      final store = _store(adapter, tmp);

      final app = _miniApp(sha256Hex: hash);
      expect(
        () => store.install(app, cancelToken: CancelToken()),
        throwsA(
          isA<MiniAppInstallException>().having(
            (e) => e.reason,
            'reason',
            MiniAppInstallFailure.invalidBundle,
          ),
        ),
      );
    },
  );

  test('install rejects archive traversal without promoting files', () async {
    final bytes = _makeTarGz({
      'index.html': [1],
      '../escape': [2],
    });
    final store = _store(_ScriptedAdapter((_) => _bodyOk(bytes)), tmp);
    await expectLater(
      store.install(
        _miniApp(sha256Hex: sha256.convert(bytes).toString()),
        cancelToken: CancelToken(),
      ),
      throwsA(isA<MiniAppInstallException>()),
    );
    expect(await store.installedVersion('demo-app'), isNull);
  });

  test(
    'local bundle validates manifest and installs with no transport',
    () async {
      final bytes = _makeTarGz({
        'manifest.json':
            '{"id":"local-demo","version":"1.0","name":{"en":"Demo"},"permissions":["car.read"],"network":[]}'
                .codeUnits,
        'index.html': '<p>local</p>'.codeUnits,
      });
      final store = _store(
        _ScriptedAdapter((_) => throw StateError('network forbidden')),
        tmp,
      );
      final manifest = await store.inspectLocalBundle(bytes);
      expect(manifest['bundleSha256'], sha256.convert(bytes).toString());
      await store.install(
        _miniApp(
          id: 'local-demo',
          version: '1.0',
          url: '',
          sha256Hex: manifest['bundleSha256'] as String,
        ),
        cancelToken: CancelToken(),
        localBytes: bytes,
      );
      expect(await store.installedVersion('local-demo'), '1.0');
    },
  );

  test('local bundle rejects privileged and invalid permissions', () async {
    final store = _store(
      _ScriptedAdapter((_) => throw StateError('network forbidden')),
      tmp,
    );
    for (final extra in [
      '"privileged":true',
      '"permissions":[42]',
      '"network":["http://localhost"]',
    ]) {
      final bytes = _makeTarGz({
        'manifest.json':
            '{"id":"demo","version":"1","name":{"en":"Demo"},$extra}'.codeUnits,
        'index.html': [1],
      });
      await expectLater(store.inspectLocalBundle(bytes), throwsFormatException);
    }
  });

  test(
    'install: missing bundleUrl throws invalidManifest pre-network',
    () async {
      final adapter = _ScriptedAdapter((_) {
        throw StateError('should not hit network');
      });
      final store = _store(adapter, tmp);
      final app = _miniApp(url: '');

      expect(
        () => store.install(app, cancelToken: CancelToken()),
        throwsA(
          isA<MiniAppInstallException>().having(
            (e) => e.reason,
            'reason',
            MiniAppInstallFailure.invalidManifest,
          ),
        ),
      );
    },
  );

  test('install: replaces a prior version of the same id', () async {
    // First install — v0.1.0.
    final v1 = _makeTarGz({'index.html': 'v1'.codeUnits});
    final v1Hash = sha256.convert(v1).toString();
    var adapter = _ScriptedAdapter((_) => _bodyOk(v1));
    var store = _store(adapter, tmp);
    await store.install(
      _miniApp(version: '0.1.0', sha256Hex: v1Hash),
      cancelToken: CancelToken(),
    );
    expect(await store.installedVersion('demo-app'), '0.1.0');

    // Second install — v0.2.0. Must replace v0.1.0; the old version
    // dir is gone, the new one's index.html is the v2 content.
    final v2 = _makeTarGz({'index.html': 'v2'.codeUnits});
    final v2Hash = sha256.convert(v2).toString();
    adapter = _ScriptedAdapter((_) => _bodyOk(v2));
    store = _store(adapter, tmp);
    await store.install(
      _miniApp(version: '0.2.0', sha256Hex: v2Hash),
      cancelToken: CancelToken(),
    );
    expect(await store.installedVersion('demo-app'), '0.2.0');
    final indexPath = await store.indexHtmlPath('demo-app');
    expect(await File(indexPath!).readAsString(), 'v2');
  });

  test('uninstall: removes the entire app dir', () async {
    final tarball = _makeTarGz({'index.html': 'x'.codeUnits});
    final hash = sha256.convert(tarball).toString();
    final adapter = _ScriptedAdapter((_) => _bodyOk(tarball));
    final store = _store(adapter, tmp);

    await store.install(_miniApp(sha256Hex: hash), cancelToken: CancelToken());
    expect(await store.installedVersion('demo-app'), '0.1.0');

    await store.uninstall('demo-app');
    expect(await store.installedVersion('demo-app'), isNull);
    expect(await store.indexHtmlPath('demo-app'), isNull);
  });

  test('install: empty body throws network failure', () async {
    final adapter = _ScriptedAdapter(
      (_) => ResponseBody.fromBytes(<int>[], 200),
    );
    final store = _store(adapter, tmp);
    final app = _miniApp(sha256Hex: 'a' * 64);
    expect(
      () => store.install(app, cancelToken: CancelToken()),
      throwsA(
        isA<MiniAppInstallException>().having(
          (e) => e.reason,
          'reason',
          MiniAppInstallFailure.network,
        ),
      ),
    );
  });
}
