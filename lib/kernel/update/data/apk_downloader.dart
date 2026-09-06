import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../kernel/api/dio_factory.dart';
import '../../services/optional_services.dart';
import '../models/release_manifest.dart';

class OtaShaMismatchException implements Exception {
  OtaShaMismatchException(this.expected, this.actual);
  final String expected;
  final String actual;

  @override
  String toString() =>
      'OtaShaMismatchException: expected=$expected actual=$actual';
}

final apkDownloaderProvider = Provider<ApkDownloader>((ref) {
  final downloader = ApkDownloader(dio: ref.watch(dioProvider(DioPurpose.cdn)));
  ref.listen(optionalServicesProvider, (_, next) {
    if (!(next.value?.contains(OptionalService.updates) ?? false)) {
      downloader.cancel();
    }
  });
  ref.onDispose(downloader.cancel);
  return downloader;
});

class ApkDownloader {
  ApkDownloader({required Dio dio, Future<Directory> Function()? directory})
    : _dio = dio,
      _directory = directory ?? getTemporaryDirectory;

  final Dio _dio;
  final Future<Directory> Function() _directory;
  CancelToken? _cancelToken;

  void cancel() => _cancelToken?.cancel('Updates disabled');

  Future<File> download(
    ReleaseManifest manifest,
    void Function(double progress) onProgress,
  ) async {
    if (manifest.sizeBytes <= 0 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(manifest.sha256)) {
      throw ArgumentError('Invalid APK size or SHA-256');
    }
    final dir = await _directory();
    final otaDir = Directory('${dir.path}/ota');
    await otaDir.create(recursive: true);
    final dest = File('${otaDir.path}/${manifest.sha256.toLowerCase()}.apk');

    // Reuse only a complete, validated APK. A Range response written with
    // Dio.download replaces the partial file, it does not append to it.
    if (await dest.exists()) {
      if (await dest.length() == manifest.sizeBytes) {
        try {
          await _verifySha(dest, manifest.sha256);
          return dest;
        } on OtaShaMismatchException {
          // A stale/corrupt cached APK is safely replaced below.
        }
      }
    }

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    await _dio.download(
      manifest.apkUrl,
      dest.path,
      deleteOnError: true,
      cancelToken: cancelToken,
      options: Options(
        extra: {'optionalService': 'updates'},
        responseType: ResponseType.bytes,
      ),
      onReceiveProgress: (received, total) {
        onProgress((received / manifest.sizeBytes).clamp(0.0, 1.0));
      },
    );

    await verifyFile(dest, manifest);
    return dest;
  }

  /// Recheck local bytes immediately before install as well as after download.
  Future<void> verifyFile(File file, ReleaseManifest manifest) async {
    if (await file.length() != manifest.sizeBytes) {
      await file.delete();
      throw StateError('Update APK size does not match release metadata');
    }
    await _verifySha(file, manifest.sha256);
  }

  // Stream-hashes the file to avoid reading the whole APK into memory.
  Future<void> _verifySha(File file, String expectedHex) async {
    final output = _CaptureSink();
    final sink = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final actual = output.value?.toString() ?? '';
    if (actual != expectedHex.toLowerCase()) {
      await file.delete();
      throw OtaShaMismatchException(expectedHex.toLowerCase(), actual);
    }
  }
}

// Single-value sink that receives the Digest emitted by sha256.
class _CaptureSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
