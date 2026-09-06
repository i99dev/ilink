import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../kernel/api/dio_factory.dart';
import '../domain/mini_app.dart';
import 'mini_app_bridge_config.dart';

/// On-device install pipeline for mini-apps.
///
/// Each version of each app lives at
/// ``<getApplicationSupportDirectory()>/mini_apps/<id>/<version>/``.
/// Install downloads the catalog's bundle tarball, hash-verifies it
/// against [MiniApp.bundleSha256], extracts to a tmp directory under
/// the same parent, and rename-promotes the tmp dir into place — so a
/// crash mid-install never leaves a partially-extracted bundle that
/// would launch and crash the WebView.
///
/// Why versioned directories: lets a new version download in
/// parallel with the old one still being launchable, then atomically
/// flip on success. Cleanup of stale versions is deferred — disk is
/// cheap, integrity isn't.
///
/// Security:
///   * Tarball bytes are SHA-256-verified before any byte is written
///     out of the tmp dir. A CDN that swaps bytes fails install.
///   * Tar member paths are normalised + rejected if they escape the
///     install root (defence against tar-slip).
///   * Symlinks / hardlinks / device nodes are skipped — only regular
///     files are written.
///   * The host never executes anything from the bundle directly;
///     the WebView's sandbox is what actually runs the mini-app.
class InstalledMiniAppStore {
  InstalledMiniAppStore({
    required Dio dio,
    Future<Directory> Function()? appSupportDirFactory,
  }) : _dio = dio,
       _appSupportDirFactory =
           appSupportDirFactory ?? getApplicationSupportDirectory;

  final Dio _dio;
  final Future<Directory> Function() _appSupportDirFactory;

  Future<Map<String, dynamic>> inspectBundledApp(MiniApp app) async {
    final bytes = await _downloadBytes(app.bundleUrl, CancelToken());
    if (sha256.convert(bytes).toString() != app.bundleSha256.toLowerCase()) {
      throw const FormatException('Bundled mini-app checksum mismatch');
    }
    final manifest = await inspectLocalBundle(bytes);
    if (manifest['id'] != app.id || manifest['version'] != app.version) {
      throw const FormatException('Bundled mini-app identity mismatch');
    }
    return manifest;
  }

  static const maxArchiveBytes = 100 * 1024 * 1024;
  static const maxExpandedBytes = 200 * 1024 * 1024;

  static void _validateSegment(String value) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$').hasMatch(value) ||
        value == '.' ||
        value == '..') {
      throw const FormatException('Invalid mini-app id or version');
    }
  }

  static Future<Archive> _decodeArchive(List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > maxArchiveBytes) {
      throw const FormatException('Bundle is empty or exceeds 100 MiB');
    }
    final expanded = BytesBuilder(copy: false);
    final chunks = <List<int>>[
      for (var i = 0; i < bytes.length; i += 16384)
        bytes.sublist(i, (i + 16384).clamp(0, bytes.length)),
    ];
    await for (final chunk in gzip.decoder.bind(Stream.fromIterable(chunks))) {
      if (expanded.length + chunk.length > maxExpandedBytes) {
        throw const FormatException('Expanded bundle exceeds 200 MiB');
      }
      expanded.add(chunk);
    }
    final archive = TarDecoder().decodeBytes(expanded.takeBytes());
    if (archive.length > 5000) {
      throw const FormatException('Too many bundle files');
    }
    final names = <String>{};
    var total = 0;
    for (final entry in archive) {
      if (entry.isDirectory && (entry.name == '.' || entry.name == './')) {
        continue;
      }
      final name = _safeRelative(entry.name);
      if (name == null || !names.add(name) || entry.isSymbolicLink) {
        throw const FormatException('Unsafe or duplicate bundle path');
      }
      total += entry.size;
      if (total > maxExpandedBytes) {
        throw const FormatException('Bundle files exceed 200 MiB');
      }
    }
    return archive;
  }

  /// Validate an owner-selected archive before the installation consent sheet.
  /// The digest records these exact bytes; it is not a publisher signature.
  Future<Map<String, dynamic>> inspectLocalBundle(List<int> bytes) async {
    final archive = await _decodeArchive(bytes);
    final manifests = archive.where(
      (e) => _safeRelative(e.name) == 'manifest.json' && e.isFile,
    );
    if (manifests.length != 1 ||
        manifests.single.size > 128 * 1024 ||
        !archive.any(
          (e) => _safeRelative(e.name) == 'index.html' && e.isFile,
        )) {
      throw const FormatException(
        'Bundle needs root manifest.json and index.html',
      );
    }
    final decoded = jsonDecode(
      utf8.decode(manifests.single.content as List<int>),
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid manifest');
    }
    final id = decoded['id'];
    final version = decoded['version'];
    if (id is! String || version is! String) {
      throw const FormatException('Missing id or version');
    }
    _validateSegment(id);
    _validateSegment(version);
    final name = decoded['name'];
    if (name is! Map ||
        name.isEmpty ||
        name.length > 32 ||
        name.entries.any(
          (e) =>
              e.key is! String ||
              e.value is! String ||
              (e.value as String).length > 256,
        )) {
      throw const FormatException('Invalid localized app name');
    }
    final permissions = decoded['permissions'] ?? const <String>[];
    if (permissions is! List ||
        permissions.length > 32 ||
        permissions.any((e) => e is! String || e.isEmpty || e.length > 64)) {
      throw const FormatException('Invalid manifest permissions');
    }
    if (decoded['privileged'] == true ||
        permissions.any((e) => (e as String).startsWith('_admin'))) {
      throw const FormatException(
        'Legacy signed privileged extensions require review',
      );
    }
    final network = decoded['network'] ?? const <String>[];
    if (network is! List ||
        network.length > 10 ||
        network.any((e) => e is! String || normalizeMiniAppOrigin(e) == null)) {
      throw const FormatException('Invalid declared network origins');
    }
    final description = decoded['description'];
    if (description != null &&
        (description is! Map ||
            description.entries.any(
              (e) => e.key is! String || e.value is! String,
            ))) {
      throw const FormatException('Invalid description');
    }
    final requires = decoded['requires'];
    if (requires != null) {
      if (requires is! Map) {
        throw const FormatException('Invalid compatibility requirements');
      }
      for (final key in ['dilink', 'vehicleCapabilities']) {
        final list = requires[key];
        if (list != null &&
            (list is! List ||
                list.isEmpty ||
                list.any((e) => e is! String || e.isEmpty))) {
          throw FormatException('Invalid compatibility requirement: $key');
        }
      }
      if ((requires['schema'] != null && requires['schema'] is! int) ||
          (requires['modernWebview'] != null &&
              requires['modernWebview'] is! bool) ||
          (requires['minBridge'] != null && requires['minBridge'] is! String)) {
        throw const FormatException('Invalid compatibility requirement types');
      }
    }
    // Imported apps never declare themselves safe to use while driving.
    return <String, dynamic>{
      ...decoded,
      'safeWhileDriving': false,
      'privileged': false,
      'certHash': null,

      'track': 'production',
      'bundleUrl': '',
      'bundleSha256': sha256.convert(bytes).toString(),
      'permissions': permissions,
      'network': [
        for (final e in network) normalizeMiniAppOrigin(e as String)!,
      ],
    };
  }

  /// Subdirectory under app-support where every install lives.
  static const _kRootDirName = 'mini_apps';
  static const _kIndexFileName = 'index.html';

  /// Resolved, lazily-cached install root. Tests inject a tmp dir via
  /// [appSupportDirFactory]; production uses ``path_provider``.
  Future<Directory> _root() async {
    final base = await _appSupportDirFactory();
    final root = Directory(p.join(base.path, _kRootDirName));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> _versionDir(String id, String version) async {
    final root = await _root();
    return Directory(p.join(root.path, id, version));
  }

  /// Returns the version currently installed for [id], or null if none.
  /// Single-version model — only the most recently installed version
  /// is kept; previous versions are removed by [install] before the
  /// new one is promoted.
  Future<String?> installedVersion(String id) async {
    final root = await _root();
    final appDir = Directory(p.join(root.path, id));
    if (!await appDir.exists()) return null;
    // The contract is "one version present". Pick the first directory
    // that actually contains an index.html — anything else is half-
    // cleaned-up state we silently ignore.
    await for (final entry in appDir.list(followLinks: false)) {
      if (entry is Directory) {
        if (p.basename(entry.path).startsWith('.')) continue;
        final idx = File(p.join(entry.path, _kIndexFileName));
        if (await idx.exists()) {
          return p.basename(entry.path);
        }
      }
    }
    return null;
  }

  /// Returns the on-disk path of an installed app's `index.html`, or
  /// null if it isn't installed. The WebView loads this via
  /// `WebUri('file://...')`. Computed via ``p.join`` so platform
  /// separators stay correct on Windows-host development.
  Future<String?> indexHtmlPath(String id) async {
    final v = await installedVersion(id);
    if (v == null) return null;
    return p.join((await _versionDir(id, v)).path, _kIndexFileName);
  }

  /// Download + verify + extract [app]'s bundle. Replaces any prior
  /// installed version of the same id atomically (extract to tmp,
  /// remove old, rename tmp into place).
  ///
  /// Throws [MiniAppInstallException] on any failure mode the caller
  /// might want to render distinctly. The original [Exception]
  /// (network, IO, hash) is wrapped so callers don't have to know
  /// about every transport implementation detail.
  Future<void> install(
    MiniApp app, {
    required CancelToken cancelToken,
    List<int>? localBytes,
  }) async {
    _validateSegment(app.id);
    _validateSegment(app.version);
    if (localBytes == null && app.bundleUrl.isEmpty) {
      throw const MiniAppInstallException(
        MiniAppInstallFailure.invalidManifest,
        'Catalog row is missing bundleUrl — nothing to download.',
      );
    }
    if (app.bundleSha256.length != 64) {
      throw const MiniAppInstallException(
        MiniAppInstallFailure.invalidManifest,
        'Catalog row is missing or has an invalid bundleSha256.',
      );
    }

    final root = await _root();
    final appDir = Directory(p.join(root.path, app.id));
    final tmpDir = Directory(
      p.join(
        appDir.path,
        '.tmp_${app.version}_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );

    try {
      // 1. Download bytes into memory. Bundles are capped at 100 MiB
      //    server-side; loading into RAM keeps the SHA + extract
      //    paths simple. If we ever lift that cap, switch to a
      //    streaming hash + tarball reader.
      final bytes =
          localBytes ?? await _downloadBytes(app.bundleUrl, cancelToken);
      if (bytes.length > maxArchiveBytes) {
        throw const FormatException('Bundle exceeds 100 MiB');
      }

      // 2. Hash-verify before any disk write.
      final actual = sha256.convert(bytes).toString();
      if (actual != app.bundleSha256.toLowerCase()) {
        throw MiniAppInstallException(
          MiniAppInstallFailure.checksumMismatch,
          'Bundle SHA-256 mismatch: expected ${app.bundleSha256}, got $actual.',
        );
      }

      // 3. Extract to tmp directory under the app's parent so the
      //    rename in step 5 is same-filesystem (atomic on POSIX).
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
      await tmpDir.create(recursive: true);
      await _extractTarGz(bytes, tmpDir);

      // 4. Sanity check — the WebView can only launch if there's an
      //    index.html. Reject before swap so we never make a broken
      //    version "live".
      if (!await File(p.join(tmpDir.path, _kIndexFileName)).exists()) {
        throw const MiniAppInstallException(
          MiniAppInstallFailure.invalidBundle,
          'Bundle does not contain an index.html at the root.',
        );
      }

      // 5. Atomic-ish swap: remove prior versions, then rename tmp to
      //    the target version dir. If the user has just upgraded, the
      //    old version is gone; if anything fails between delete +
      //    rename, install() returns failure and the next attempt
      //    starts clean.
      final target = await _versionDir(app.id, app.version);
      await _wipeAppDir(appDir, except: tmpDir.path);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await tmpDir.rename(target.path);
    } on MiniAppInstallException {
      await _safeDelete(tmpDir);
      rethrow;
    } on DioException catch (e) {
      await _safeDelete(tmpDir);
      if (CancelToken.isCancel(e)) {
        throw const MiniAppInstallException(
          MiniAppInstallFailure.cancelled,
          'Install was cancelled.',
        );
      }
      throw MiniAppInstallException(
        MiniAppInstallFailure.network,
        'Network error while downloading bundle: ${e.message ?? e.type}',
      );
    } catch (e, st) {
      await _safeDelete(tmpDir);
      if (kDebugMode) {
        debugPrint('install: unexpected failure: $e\n$st');
      }
      throw MiniAppInstallException(
        MiniAppInstallFailure.unknown,
        'Install failed: $e',
      );
    }
  }

  /// Recursively removes the on-disk install for [id]. No-op when
  /// nothing is installed.
  Future<void> uninstall(String id) async {
    final root = await _root();
    final appDir = Directory(p.join(root.path, id));
    if (await appDir.exists()) {
      await appDir.delete(recursive: true);
    }
  }

  // ── internals ──────────────────────────────────────────────────────

  Future<List<int>> _downloadBytes(String url, CancelToken cancelToken) async {
    if (url.startsWith('asset:')) {
      final uri = Uri.parse(url);
      final asset = uri.path.replaceFirst(RegExp(r'^/'), '');
      if (uri.host.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !RegExp(
            r'^assets/offline/mini_apps/[a-zA-Z0-9][a-zA-Z0-9._-]*\.tar\.gz$',
          ).hasMatch(asset)) {
        throw const FormatException('Invalid bundled mini-app asset path');
      }
      final bytes = await rootBundle.load(asset);
      if (bytes.lengthInBytes > maxArchiveBytes) {
        throw const FormatException('Bundle exceeds 100 MiB');
      }
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    }
    final response = await _dio.get<List<int>>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.bytes,
        // Bundles are gzip on the wire; Dio decompresses by default.
        // We want the raw .tar.gz bytes (not the unzipped tar) so the
        // SHA matches what the server computed at submit time.
        receiveDataWhenStatusError: false,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw const MiniAppInstallException(
        MiniAppInstallFailure.network,
        'Bundle response was empty.',
      );
    }
    return body;
  }

  Future<void> _extractTarGz(List<int> bytes, Directory target) async {
    // gzip → tar → TarDecoder. The archive package keeps everything
    // in memory; for 100MB caps that's fine on a head unit (RAM is
    // a few GB) and keeps the API synchronous.
    final archive = await _decodeArchive(bytes);
    for (final entry in archive) {
      if (!entry.isFile) continue; // directories, symlinks, hardlinks
      final rel = _safeRelative(entry.name);
      if (rel == null) continue; // path traversal — silently drop
      final outPath = p.join(target.path, rel);
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>, flush: false);
    }
  }

  /// Returns the safe relative path for [name], or null if it escapes
  /// the extraction root (tar-slip defence).
  static String? _safeRelative(String name) {
    var n = name;
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    if (n.startsWith('/') ||
        n.contains('\\') ||
        n.contains(':') ||
        n.contains('\u0000') ||
        n.split('/').contains('..')) {
      return null;
    }
    if (n.isEmpty) return null;
    final norm = p.posix.normalize(n);
    if (norm == '.' || norm == '..') return null;
    if (norm.startsWith('../') ||
        norm.contains('/../') ||
        norm.startsWith('/')) {
      return null;
    }
    return norm;
  }

  Future<void> _wipeAppDir(Directory appDir, {required String except}) async {
    if (!await appDir.exists()) return;
    await for (final entry in appDir.list(followLinks: false)) {
      if (entry.path == except) continue;
      await entry.delete(recursive: true);
    }
  }

  Future<void> _safeDelete(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Cleanup best-effort — a leftover tmp dir is harmless and
      // gets clobbered on the next install of the same id.
    }
  }
}

enum MiniAppInstallFailure {
  /// Bundle bytes' SHA-256 did not match the catalog's claim.
  checksumMismatch,

  /// Catalog row was missing bundleUrl or bundleSha256.
  invalidManifest,

  /// Bundle had no index.html or otherwise wasn't a valid mini-app.
  invalidBundle,

  /// Caller cancelled the install.
  cancelled,

  /// Network error (transport, 5xx, etc.).
  network,

  /// Anything else — disk full, permissions, OS API failures.
  unknown,
}

class MiniAppInstallException implements Exception {
  const MiniAppInstallException(this.reason, this.message);

  final MiniAppInstallFailure reason;
  final String message;

  @override
  String toString() => 'MiniAppInstallException($reason): $message';
}

/// JSON helpers retained for tests / debugging — handy when adding
/// future state (e.g. last-launched timestamp) to the install dir.
@visibleForTesting
String encodeMetaForTest(Map<String, Object?> meta) => jsonEncode(meta);

final installedMiniAppStoreProvider = Provider<InstalledMiniAppStore>((ref) {
  // Bundle downloads bypass the ApiClient (envelope unwrap, refresh
  // logic, etc. don't apply to a raw CDN binary) — but they still go
  // through the centralized factory (DioPurpose.cdn) so timeouts +
  // connection-pool reuse are consistent with the rest of the app.
  // A bare `Dio()` here had no timeouts: a stalled cellular download
  // hung the install until the user cancelled.
  return InstalledMiniAppStore(dio: ref.watch(dioProvider(DioPurpose.cdn)));
});
