import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/update/data/apk_downloader.dart';
import 'package:ilink/kernel/update/models/release_manifest.dart';

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes, this.requests);
  final List<int> Function() bytes;
  final List<RequestOptions> requests;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(bytes(), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory temp;
  late ApkDownloader downloader;
  late ReleaseManifest manifest;
  late List<int> servedBytes;
  late List<RequestOptions> requests;
  final bytes = List.generate(128, (i) => i);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ilink-ota-test-');
    servedBytes = bytes;
    requests = [];
    final dio = Dio()
      ..httpClientAdapter = _BytesAdapter(() => servedBytes, requests);
    downloader = ApkDownloader(dio: dio, directory: () async => temp);
    manifest = ReleaseManifest(
      versionCode: 100,
      versionName: '4.0.0',
      apkUrl:
          'https://github.com/i99dev/ilink/releases/download/v4.0.0/ilink.apk',
      sha256: sha256.convert(bytes).toString(),
      sizeBytes: bytes.length,
      signerSha256: '',
      forceUpdate: false,
      releasedAt: DateTime.utc(2026),
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<File> seed(List<int> data) async {
    final file = File('${temp.path}/ota/${manifest.sha256}.apk');
    await file.parent.create(recursive: true);
    return file.writeAsBytes(data);
  }

  test('downloads and reuses only verified complete local APK', () async {
    final file = await downloader.download(manifest, (_) {});
    expect(await file.readAsBytes(), bytes);
    await downloader.download(manifest, (_) {});
    expect(requests, hasLength(1));
  });
  test('restarts partial cache without broken Range overwrite', () async {
    await seed(bytes.take(20).toList());
    final file = await downloader.download(manifest, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(requests.single.headers['Range'], isNull);
  });
  test('replaces corrupt complete cache on same attempt', () async {
    await seed(List.filled(bytes.length, 0));
    final file = await downloader.download(manifest, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(requests, hasLength(1));
  });
  test('rejects and deletes truncated download', () async {
    servedBytes = bytes.take(20).toList();
    await expectLater(downloader.download(manifest, (_) {}), throwsStateError);
    expect(
      await File('${temp.path}/ota/${manifest.sha256}.apk').exists(),
      isFalse,
    );
  });
  test('rejects altered bytes immediately before install', () async {
    final file = await seed(List.filled(bytes.length, 0));
    await expectLater(
      downloader.verifyFile(file, manifest),
      throwsA(isA<OtaShaMismatchException>()),
    );
    expect(await file.exists(), isFalse);
  });
}
