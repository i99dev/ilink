import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/native_apps/data/local_apk_importer.dart';

void main() {
  late Directory temp;
  late File source;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local_apk_test_');
    source = await File('${temp.path}/source.apk').writeAsBytes([1, 2, 3]);
  });
  tearDown(() => temp.delete(recursive: true));

  test('stages exact bytes and invokes consent installer', () async {
    File? installed;
    final importer = LocalApkImporter(
      stagingDirectory: () async => Directory('${temp.path}/staging'),
      inspect: (_) async => {
        'packageName': 'com.example.app',
        'versionCode': 4,
        'actual': 'a' * 64,
      },
      installedVersion: (_) async => 3,
      installer: (file) async {
        installed = file;
      },
    );
    await importer.install(source.path, expectedPackage: 'com.example.app');
    expect(installed!.path, isNot(source.path));
    expect(await installed!.readAsBytes(), [1, 2, 3]);
  });

  for (final invalid in [
    {'packageName': 'com.other.app', 'versionCode': 4, 'actual': 'a' * 64},
    {'packageName': 'com.example.app', 'versionCode': 2, 'actual': 'a' * 64},
    {'packageName': 'com.example.app', 'versionCode': 4, 'actual': ''},
  ]) {
    test(
      'rejects invalid package, downgrade or absent certificate: $invalid',
      () async {
        var installs = 0;
        final importer = LocalApkImporter(
          stagingDirectory: () async => Directory('${temp.path}/staging'),
          inspect: (_) async => invalid,
          installedVersion: (_) async => 3,
          installer: (_) async {
            installs++;
          },
        );
        await expectLater(
          importer.install(source.path, expectedPackage: 'com.example.app'),
          throwsStateError,
        );
        expect(installs, 0);
      },
    );
  }
}
