import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ota_channel.dart';

class OtaInstallDeniedException implements Exception {
  @override
  String toString() =>
      'OtaInstallDeniedException: REQUEST_INSTALL_PACKAGES denied';
}

final apkInstallerProvider = Provider<ApkInstaller>((_) => ApkInstaller());

class ApkInstaller {
  static const _channel = otaMethodChannel;

  // Ensures the user has granted REQUEST_INSTALL_PACKAGES, then hands the
  // APK to PackageInstaller. If the permission is missing, opens the system
  // settings page for the user to grant it; the caller should re-invoke
  // after the user returns.
  Future<void> install(File apkFile) async {
    final canInstall = await _channel.invokeMethod<bool>('canInstallPackages');
    if (canInstall != true) {
      // Opens ACTION_MANAGE_UNKNOWN_APP_SOURCES for our package. The user
      // must flip the toggle and return before the install can proceed.
      await _channel.invokeMethod<void>('openInstallSettings');
      throw OtaInstallDeniedException();
    }
    await _channel.invokeMethod<void>('installApk', {'path': apkFile.path});
  }
}
