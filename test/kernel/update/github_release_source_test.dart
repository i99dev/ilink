import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/update/data/github_release_source.dart';

void main() {
  late Dio dio;
  late GitHubReleaseSource source;
  late Map<String, dynamic> release;
  late Map<String, dynamic> metadata;
  late List<RequestOptions> requests;
  const base = 'https://github.com/i99dev/ilink/releases/download/v4.0.0';
  final sha = 'a' * 64;

  setUp(() {
    release = {
      'draft': false,
      'prerelease': false,
      'tag_name': 'v4.0.0',
      'published_at': '2026-09-06T12:00:00Z',
      'body': 'Changes',
      'assets': [
        {
          'name': 'ilink.apk',
          'state': 'uploaded',
          'size': 123,
          'digest': 'sha256:$sha',
          'browser_download_url': '$base/ilink.apk',
        },
        {
          'name': 'ilink-release.json',
          'state': 'uploaded',
          'size': 256,
          'browser_download_url': '$base/ilink-release.json',
        },
        {
          'name': 'unrelated.apk',
          'state': 'uploaded',
          'size': 123,
          'browser_download_url': '$base/unrelated.apk',
        },
      ],
    };
    metadata = {
      'versionName': '4.0.0',
      'versionCode': 100,
      'sha256': sha,
      'sizeBytes': 123,
    };
    requests = [];
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: request.uri.host == 'api.github.com' ? release : metadata,
            ),
          );
        },
      ),
    );
    source = GitHubReleaseSource(dio: dio);
  });

  test('rejects an asset belonging to the old repository', () async {
    // The retired i99dash repository, not the configured one. An update must
    // never be accepted from a repository other than [source]'s own, however
    // plausible the asset name looks.
    (release['assets'] as List).first['browser_download_url'] =
        'https://github.com/i99dev/i99dash/releases/download/v4.0.0/ilink.apk';
    expect(await source.latest(installedVersionCode: 99), isNull);
  });

  test(
    'selects exact universal APK, preserves version and verifies metadata',
    () async {
      final result = await source.latest(installedVersionCode: 99);
      expect(result?.apkUrl, '$base/ilink.apk');
      expect(result?.versionCode, 100);
      expect(result?.sha256, sha);
      expect(result?.forceUpdate, false);
      expect(result?.signerSha256, isEmpty);
      expect(requests.first.uri.toString(), GitHubReleaseSource.latestUrl);
      expect(
        requests.every((r) => !r.headers.containsKey('Authorization')),
        isTrue,
      );
      expect(
        requests.every((r) => r.extra['optionalService'] == 'updates'),
        isTrue,
      );
    },
  );

  for (final code in [100, 101]) {
    test('does not offer same version or downgrade from $code', () async {
      expect(await source.latest(installedVersionCode: code), isNull);
    });
  }
  for (final flag in ['draft', 'prerelease']) {
    test('ignores $flag without downloading metadata', () async {
      release[flag] = true;
      expect(await source.latest(installedVersionCode: 0), isNull);
      expect(requests, hasLength(1));
    });
  }
  test('rejects asset redirects to another repository', () async {
    (release['assets'] as List).first['browser_download_url'] =
        'https://github.com/other/app/releases/download/v4.0.0/ilink.apk';
    expect(await source.latest(installedVersionCode: 0), isNull);
    expect(requests, hasLength(1));
  });
  test('does not guess between duplicate APK assets', () async {
    final assets = release['assets'] as List;
    assets.add(assets.first);
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
  test('rejects hash disagreement with GitHub digest', () async {
    metadata['sha256'] = 'b' * 64;
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
  test('rejects APK size disagreement', () async {
    metadata['sizeBytes'] = 124;
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
  test('rejects metadata from a different version tag', () async {
    metadata['versionName'] = '5.0.0';
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
  test('malformed API field does not crash app', () async {
    release['published_at'] = 123;
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
  test('offline and rate limit errors are nonfatal', () async {
    dio.interceptors.clear();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) {
          h.reject(
            DioException(
              requestOptions: r,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );
    expect(await source.latest(installedVersionCode: 0), isNull);
  });
}
