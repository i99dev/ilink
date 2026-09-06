import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/release_manifest.dart';
import 'release_source.dart';

/// Unauthenticated public releases. Metadata never supplies a trusted signer:
/// archive verification uses the application's existing platform signer pin.
class GitHubReleaseSource implements ReleaseSource {
  GitHubReleaseSource({required Dio dio}) : _dio = dio;

  static const repository = String.fromEnvironment(
    'GITHUB_RELEASE_REPOSITORY',
    defaultValue: 'i99dev/ilink',
  );
  static const downloadsUrl = 'https://github.com/$repository/releases';
  static const latestUrl =
      'https://api.github.com/repos/$repository/releases/latest';
  static const apkName = 'ilink.apk';
  static const metadataName = 'ilink-release.json';
  final Dio _dio;

  @override
  Future<ReleaseManifest?> latest({required int installedVersionCode}) async {
    try {
      final response = await _dio.get<Object?>(
        latestUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2026-03-10',
          },
          extra: {'optionalService': 'updates'},
        ),
      );
      if (response.statusCode != 200) return null;
      final release = response.data;
      if (release is! Map<String, dynamic> ||
          release['draft'] != false ||
          release['prerelease'] != false) {
        return null;
      }
      final tag = release['tag_name'];
      final published = DateTime.tryParse(
        release['published_at'] as String? ?? '',
      );
      final assets = release['assets'];
      if (tag is! String ||
          tag.isEmpty ||
          published == null ||
          assets is! List) {
        return null;
      }

      Map<String, dynamic>? asset(String name) {
        final matches = assets
            .whereType<Map<String, dynamic>>()
            .where((a) => a['name'] == name && a['state'] == 'uploaded')
            .toList();
        if (matches.length != 1) return null;
        final a = matches.single;
        final uri = Uri.tryParse(a['browser_download_url'] as String? ?? '');
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host != 'github.com' ||
            uri.hasPort ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            !_samePath(uri.pathSegments, [
              ...repository.split('/'),
              'releases',
              'download',
              tag,
              name,
            ])) {
          return null;
        }
        return a;
      }

      final apk = asset(apkName);
      final metadata = asset(metadataName);
      if (apk == null || metadata == null) return null;
      final metadataSize = metadata['size'];
      if (metadataSize is! int ||
          metadataSize <= 0 ||
          metadataSize > 64 * 1024) {
        return null;
      }
      final details = await _dio.get<Object?>(
        metadata['browser_download_url'] as String,
        options: Options(extra: {'optionalService': 'updates'}),
      );
      if (details.statusCode != 200) return null;
      final data = details.data is String
          ? jsonDecode(details.data as String)
          : details.data;
      if (data is! Map<String, dynamic>) return null;
      final code = data['versionCode'];
      final name = data['versionName'];
      final digest = data['sha256'];
      final size = data['sizeBytes'];
      if (code is! int ||
          code <= installedVersionCode ||
          code <= 0 ||
          name is! String ||
          name.isEmpty ||
          tag != 'v$name' ||
          digest is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) ||
          size is! int ||
          size <= 0 ||
          size != apk['size']) {
        return null;
      }
      final apiDigest = apk['digest'];
      if (apiDigest != null && apiDigest != 'sha256:${digest.toLowerCase()}') {
        return null;
      }
      return ReleaseManifest(
        versionCode: code,
        versionName: name,
        apkUrl: apk['browser_download_url'] as String,
        sha256: digest.toLowerCase(),
        sizeBytes: size,
        signerSha256: '', // Never trust a remote signing certificate pin.
        forceUpdate: false,
        releasedAt: published,
        releaseNotes: release['body'] as String?,
        package: 'com.i99dev.ilink',
      );
    } catch (_) {
      // Offline, private/missing repo, rate limiting and invalid metadata cannot
      // prevent normal device operation. The next user-enabled check can retry.
      return null;
    }
  }

  static bool _samePath(List<String> actual, List<String> expected) =>
      actual.length == expected.length &&
      List.generate(
        actual.length,
        (i) => actual[i] == expected[i],
      ).every((v) => v);
}
