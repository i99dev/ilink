import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../kernel/update/data/apk_installer.dart';
import '../../../kernel/update/data/ota_channel.dart';
import '../../home/state/installed_apps_provider.dart';

final localApkImporterProvider = Provider<LocalApkImporter>((ref) {
  return LocalApkImporter(
    stagingDirectory: () async =>
        Directory('${(await getTemporaryDirectory()).path}/local-apk-imports'),
    inspect: (path) async =>
        await otaMethodChannel.invokeMapMethod<String, dynamic>(
          'checkApkSigner',
          {'apkPath': path},
        ) ??
        const {},
    installedVersion: (package) async {
      final packages = await ref
          .read(pkgBridgeProvider)
          .list(includeSystem: true);
      for (final p in packages) {
        if (p.packageName == package) return p.versionCode;
      }
      return 0;
    },
    installer: (file) => ref.read(apkInstallerProvider).install(file),
  );
});

/// Imports owner-selected APKs. Hash verification protects the private staged
/// copy; Android PackageInstaller verifies APK signatures, installed signer
/// continuity and install permission, with its normal consent dialog.
class LocalApkImporter {
  LocalApkImporter({
    required this.stagingDirectory,
    required this.inspect,
    required this.installedVersion,
    required this.installer,
  });
  final Future<Directory> Function() stagingDirectory;
  final Future<Map<String, dynamic>> Function(String) inspect;
  final Future<int> Function(String) installedVersion;
  final Future<void> Function(File) installer;

  Future<void> install(String selectedPath, {String? expectedPackage}) async {
    final source = File(selectedPath);
    final size = await source.length();
    if (size <= 0 || size > 2 * 1024 * 1024 * 1024) {
      throw StateError('APK is empty or exceeds 2 GiB');
    }
    final digest = await sha256.bind(source.openRead()).first;
    final directory = await stagingDirectory();
    await directory.create(recursive: true);
    final operation = await directory.createTemp('import_');
    final staged = await source.copy('${operation.path}/$digest.apk');
    if (await staged.length() != size ||
        await sha256.bind(staged.openRead()).first != digest) {
      throw StateError('APK changed while importing');
    }
    final metadata = await inspect(staged.path);
    final package = metadata['packageName'] as String? ?? '';
    final signer = (metadata['actual'] as String? ?? '')
        .replaceAll(':', '')
        .toLowerCase();
    final version = (metadata['versionCode'] as num?)?.toInt() ?? 0;
    if (!RegExp(
          r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
        ).hasMatch(package) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(signer) ||
        version <= 0) {
      throw StateError(
        'APK package, version or signing certificate is invalid',
      );
    }
    if (expectedPackage != null && package != expectedPackage) {
      throw StateError('Selected APK belongs to another application');
    }
    if (version < await installedVersion(package)) {
      throw StateError('An older APK cannot replace the installed version');
    }
    // Retain the staged file while the asynchronous system installer reads it.
    await installer(staged);
  }
}
