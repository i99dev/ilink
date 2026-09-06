import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/app/update/release_source_provider.dart';
import 'package:ilink/app/update/ui/update_prompt.dart';
import 'package:ilink/app/update/update_controller.dart';
import 'package:ilink/app/update/update_orchestrator.dart';
import 'package:ilink/app/update/update_state.dart';
import 'package:ilink/kernel/api/dio_factory.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:ilink/kernel/lifecycle/app_lifecycle_bus.dart';
import 'package:ilink/kernel/update/data/github_release_source.dart';
import 'package:ilink/kernel/update/data/ota_channel.dart';

const _package = 'com.i99dev.ilink';
const _signer =
    '2a4700925fe0c230c9bac63ab194ff9500a58a4ac0825c2196ee9ac7f33fc264';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
  @override
  Future<String?> getExternalStoragePath() async => directory.path;
}

/// Only HTTP is faked: real Dio transforms/interceptors and all OTA services run.
class _GitHubHttp implements HttpClientAdapter {
  int releaseCode = 10001;
  int latestStatus = 200;
  bool corruptApk = false;
  Completer<void>? holdLatest;
  Completer<void>? holdApk;
  final requests = <RequestOptions>[];
  int get latestCalls => requests
      .where((r) => r.uri.toString() == GitHubReleaseSource.latestUrl)
      .length;
  int get apkCalls =>
      requests.where((r) => r.uri.path.endsWith('/ilink.apk')).length;
  List<int> bytes(int code) => List.generate(256, (i) => (i + code) % 256);
  String version(int code) => '3.22.${code - 10000}-b';
  String base(int code) =>
      'https://github.com/${GitHubReleaseSource.repository}/releases/download/v${version(code)}';
  Map<String, Object> metadata(int code) => {
    'versionCode': code,
    'versionName': version(code),
    'sha256': sha256.convert(bytes(code)).toString(),
    'sizeBytes': bytes(code).length,
  };
  ResponseBody json(Object data, {int status = 200}) => ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.toString() == GitHubReleaseSource.latestUrl) {
      final code = releaseCode;
      final hold = holdLatest;
      holdLatest = null;
      if (hold != null) await hold.future;
      if (latestStatus != 200) {
        return json({'message': 'Unavailable'}, status: latestStatus);
      }
      return json({
        'draft': false,
        'prerelease': false,
        'tag_name': 'v${version(code)}',
        'published_at': '2026-09-07T12:00:00Z',
        'body': 'Future standalone release',
        'assets': [
          {
            'name': 'ilink.apk',
            'state': 'uploaded',
            'size': bytes(code).length,
            'digest': 'sha256:${sha256.convert(bytes(code))}',
            'browser_download_url': '${base(code)}/ilink.apk',
          },
          {
            'name': 'ilink-release.json',
            'state': 'uploaded',
            'size': utf8.encode(jsonEncode(metadata(code))).length,
            'browser_download_url': '${base(code)}/ilink-release.json',
          },
        ],
      });
    }
    for (final code in [10001, 10002]) {
      if (options.uri.toString() == '${base(code)}/ilink-release.json') {
        return json(metadata(code));
      }
      if (options.uri.toString() == '${base(code)}/ilink.apk') {
        final hold = holdApk;
        holdApk = null;
        if (hold != null) await hold.future;
        final body = corruptApk
            ? List<int>.filled(bytes(code).length, 0)
            : bytes(code);
        return ResponseBody.fromBytes(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [
              'application/vnd.android.package-archive',
            ],
            Headers.contentLengthHeader: ['${body.length}'],
          },
        );
      }
    }
    throw StateError('Unexpected HTTP request: ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

class _Harness {
  _Harness(this.container, this.http, this.directory);
  final ProviderContainer container;
  final _GitHubHttp http;
  final Directory directory;
  DateTime now = DateTime.utc(2026, 9, 7);
  bool canInstall = false;
  String archiveSigner = _signer;
  final platformCalls = <MethodCall>[];
  bool installerHandoffComplete = false;
  UpdateState? get state => container.read(updateControllerProvider).value;
  UpdateController get controller =>
      container.read(updateControllerProvider.notifier);
  int calls(String method) =>
      platformCalls.where((c) => c.method == method).length;
  void resume() => container
      .read(appLifecycleBusProvider)
      .didChangeAppLifecycleState(AppLifecycleState.resumed);
  void pause() => container
      .read(appLifecycleBusProvider)
      .didChangeAppLifecycleState(AppLifecycleState.paused);
  Future<void> enable(bool value) => container
      .read(optionalServicesProvider.notifier)
      .setEnabled(OptionalService.updates, value);
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 1000 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue, reason: 'OTA condition did not become ready');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Harness h;
  late PathProviderPlatform originalPaths;

  Future<void> start({bool consent = true, Completer<void>? holdLatest}) async {
    SharedPreferences.setMockInitialValues({
      if (consent) DeviceServicePreferences.key: ['updates'],
    });
    PackageInfo.setMockInitialValues(
      appName: 'ilink',
      packageName: _package,
      version: '3.22.0-b',
      buildNumber: '10000',
      buildSignature: _signer,
    );
    final directory = await Directory.systemTemp.createTemp(
      'ilink-github-continuity-',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    final http = _GitHubHttp()..holdLatest = holdLatest;
    late ProviderContainer container;
    container = ProviderContainer(
      overrides: [updateClockProvider.overrideWithValue(() => h.now)],
    );
    h = _Harness(container, http, directory);
    container.read(dioProvider(DioPurpose.cdn)).httpClientAdapter = http;
    messenger.setMockMethodCallHandler(otaMethodChannel, (call) async {
      h.platformCalls.add(call);
      switch (call.method) {
        case 'checkApkSigner':
          return {
            'ok': h.archiveSigner == _signer,
            'expected': _signer,
            'actual': h.archiveSigner,
            'packageName': _package,
            'versionCode': http.releaseCode,
          };
        case 'canInstallPackages':
          return h.canInstall;
        case 'openInstallSettings':
          return null;
        case 'installApk':
          expect(
            await File((call.arguments as Map)['path'] as String).readAsBytes(),
            http.bytes(http.releaseCode),
          );
          h.installerHandoffComplete = true;
          return null; // Simulated Android handoff only; no package is installed.
      }
      throw StateError('Unexpected OTA platform call ${call.method}');
    });
    for (final name in [
      'ilink/voice/events',
      'ilink/ondevice_voice',
      'ilink/ondevice_voice/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    await container.read(optionalServicesProvider.future);
    await container.read(updateControllerProvider.future);
    expect(container.read(releaseSourceProvider), isA<GitHubReleaseSource>());
    // This is the production registration used by BootSequence. It owns the
    // saved-consent/enable listener and fires without a manual check call.
    container.listen(updateOrchestratorProvider, (_, _) {});
  }

  tearDown(() async {
    h.container.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(otaMethodChannel, null);
    for (final name in [
      'ilink/voice/events',
      'ilink/ondevice_voice',
      'ilink/ondevice_voice/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    PathProviderPlatform.instance = originalPaths;
    await h.directory.delete(recursive: true);
  });

  testWidgets(
    '10000 discovers10001 automatically; owner taps download then installer permission and handoff',
    (tester) async {
      await tester.runAsync(() async {
        await start();
        await _until(
          () =>
              h.container.read(promptUpdateProvider)?.manifest.versionCode ==
              10001,
        );
      });
      expect(h.state, isA<UpdateAvailable>());
      expect(h.http.apkCalls, 0);
      expect(h.platformCalls, isEmpty);
      expect(
        h.http.requests.every((r) => !r.headers.containsKey('Authorization')),
        isTrue,
      );
      expect(
        h.http.requests.every((r) => r.extra['optionalService'] == 'updates'),
        isTrue,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: UpdatePromptDialog(
                manifest: (h.state as UpdateAvailable).manifest,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Install now'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Install now'));
        await _until(() => h.state is UpdateReadyToInstall);
      });
      await tester.pumpAndSettle();
      expect(h.http.apkCalls, 1);
      expect(h.calls('checkApkSigner'), 1);
      expect(h.calls('installApk'), 0);
      expect(h.calls('canInstallPackages'), 0);
      // The second explicit tap checks unknown-source permission. Missing
      // permission opens Android settings and preserves the verified download.
      await tester.runAsync(() async {
        await tester.tap(find.text('Install now'));
        await _until(
          () =>
              h.calls('openInstallSettings') == 1 &&
              h.state is UpdateReadyToInstall,
        );
      });
      await tester.pumpAndSettle();
      expect(h.calls('installApk'), 0);
      h.canInstall = true;
      await tester.runAsync(() async {
        h.resume();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(
        h.calls('installApk'),
        0,
        reason:
            'Returning from permission settings must not install automatically',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Install now'));
        await _until(() => h.installerHandoffComplete);
      });
      expect(
        h.calls('checkApkSigner'),
        3,
        reason:
            'Actual archive identity is checked after download and before each handoff attempt',
      );
      expect(h.state, isA<UpdateInstalling>());
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'default-off boot, resume and manual check make no HTTP request; enable discovers automatically',
    () async {
      await start(consent: false);
      h.resume();
      await h.controller.check();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.http.requests, isEmpty);
      expect(h.container.read(promptUpdateProvider), isNull);
      await h.enable(true);
      await _until(() => h.container.read(promptUpdateProvider) != null);
      expect(h.http.latestCalls, 1);
      expect(h.http.apkCalls, 0);
      expect(h.calls('installApk'), 0);
    },
  );

  test(
    'resume uses one-hour cooldown and slow response still prompts while foreground',
    () async {
      await start();
      await _until(() => h.container.read(promptUpdateProvider) != null);
      h.controller.defer();
      h.container.read(promptUpdateProvider.notifier).value = null;
      h.now = h.now.add(const Duration(minutes: 30));
      h.resume();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.http.latestCalls, 1);
      h.now = h.now.add(const Duration(minutes: 30));
      h.resume();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        h.http.latestCalls,
        1,
        reason: 'Exactly one hour is still within cooldown',
      );
      final response = Completer<void>();
      h.http.holdLatest = response;
      h.now = h.now.add(const Duration(hours: 25));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        h.http.latestCalls,
        1,
        reason: 'Elapsed time alone is not a polling trigger',
      );
      h.resume();
      await _until(() => h.http.latestCalls == 2);
      h.now = h.now.add(const Duration(seconds: 2));
      response.complete();
      await _until(() => h.container.read(promptUpdateProvider) != null);
      expect(h.http.apkCalls, 0);
    },
  );

  test(
    'background response parks until resume without another fetch',
    () async {
      final response = Completer<void>();
      await start(holdLatest: response);
      await _until(() => h.http.latestCalls == 1);
      h.pause();
      response.complete();
      await _until(() => h.state is UpdateAvailable);
      expect(h.container.read(promptUpdateProvider), isNull);
      h.resume();
      await _until(() => h.container.read(promptUpdateProvider) != null);
      expect(h.http.latestCalls, 1);
    },
  );

  test(
    'revocation during old request then re-enable can discover a newer response',
    () async {
      final stale = Completer<void>();
      await start(holdLatest: stale);
      await _until(() => h.http.latestCalls == 1);
      await h.enable(false);
      h.http.releaseCode = 10002;
      await h.enable(true);
      await _until(
        () =>
            h.container.read(promptUpdateProvider)?.manifest.versionCode ==
            10002,
      );
      stale.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((h.state as UpdateAvailable).manifest.versionCode, 10002);
      expect(h.http.latestCalls, 2);
      expect(h.http.apkCalls, 0);
    },
  );

  test(
    'automatic checks do not replace a download or ready-to-install state',
    () async {
      await start();
      await _until(() => h.state is UpdateAvailable);
      final bytes = Completer<void>();
      h.http.holdApk = bytes;
      final downloading = h.controller.download();
      await _until(() => h.http.apkCalls == 1);
      h.now = h.now.add(const Duration(hours: 25));
      h.resume();
      await h.controller.check();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.state, isA<UpdateDownloading>());
      expect(h.http.latestCalls, 1);
      bytes.complete();
      await downloading;
      h.resume();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.state, isA<UpdateReadyToInstall>());
      expect(h.http.latestCalls, 1);
      expect(h.calls('installApk'), 0);
      await h.enable(false);
      await h.controller.install();
      expect(h.state, isA<UpdateIdle>());
      expect(h.calls('installApk'), 0);
    },
  );

  test('corrupt HTTP APK never reaches signer or installer', () async {
    await start();
    await _until(() => h.state is UpdateAvailable);
    h.http.corruptApk = true;
    await h.controller.download();
    expect(h.state, isA<UpdateFailed>());
    expect((h.state as UpdateFailed).isFatal, isTrue);
    expect(h.calls('checkApkSigner'), 0);
    expect(h.calls('installApk'), 0);
  });

  test('platform signer mismatch rejects a hash-valid download', () async {
    await start();
    await _until(() => h.state is UpdateAvailable);
    h.archiveSigner = 'b' * 64;
    await h.controller.download();
    expect(h.state, isA<UpdateFailed>());
    expect((h.state as UpdateFailed).isFatal, isTrue);
    expect(h.calls('installApk'), 0);
  });
}
