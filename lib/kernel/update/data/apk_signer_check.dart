import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ota_channel.dart';

class OtaSignerMismatchException implements Exception {
  OtaSignerMismatchException(this.expected, this.actual);
  final String expected;
  final String actual;

  @override
  String toString() =>
      'OtaSignerMismatchException: expected=$expected actual=$actual';
}

final apkSignerCheckProvider = Provider<ApkSignerCheck>(
  (_) => ApkSignerCheck(),
);

class ApkSignerCheck {
  static const _channel = otaMethodChannel;

  // Verifies that the APK at [apkPath] was signed with the same key as
  // the running app. The Kotlin helper reads the signing cert from the
  // archive and compares against the compile-time EXPECTED_SIGNER_SHA
  // already injected into BuildConfig by build.gradle.kts:132-135.
  Future<void> verify(
    String apkPath, {
    String? expectedPackage,
    int? expectedVersionCode,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'checkApkSigner',
      {'apkPath': apkPath},
    );
    if (result == null) {
      throw OtaSignerMismatchException('(unknown)', '(null result)');
    }
    final ok = result['ok'] as bool? ?? false;
    final expected = (result['expected'] as String? ?? '')
        .replaceAll(':', '')
        .toLowerCase();
    final actual = (result['actual'] as String? ?? '')
        .replaceAll(':', '')
        .toLowerCase();
    if (!ok ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) ||
        expected != actual) {
      final expected = result['expected'] as String? ?? '';
      final actual = result['actual'] as String? ?? '';
      throw OtaSignerMismatchException(expected, actual);
    }
    if (expectedPackage != null && result['packageName'] != expectedPackage) {
      throw StateError('Update APK package does not match this application');
    }
    if (expectedVersionCode != null &&
        result['versionCode'] != expectedVersionCode) {
      throw StateError(
        'Update APK version does not match the release metadata',
      );
    }
  }
}
