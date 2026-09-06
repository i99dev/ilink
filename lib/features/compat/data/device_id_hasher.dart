import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hashes the VIN before it leaves the device so the compat backend
/// never stores raw VINs. 16 hex chars of sha256 is plenty of entropy
/// to correlate reports from the same car (collision space ≈ 2^64)
/// while not being reversible to a raw 17-char VIN.
///
/// **⚠️ NEVER CHANGE [_salt].** The salt is the join key for every
/// historical report — rotating it re-hashes every car and breaks the
/// ability to correlate old reports with new ones for the same VIN.
/// If the salt must change, bump `schema_version` in the compat report
/// and ship the app with both hashes during the deprecation window.
class DeviceIdHasher {
  DeviceIdHasher._();

  static const _salt = 'BYD_DASH_V1_2026_SALT_DO_NOT_CHANGE';

  /// `null` in / empty string → `null` out (signal "user opted out").
  /// Non-empty VIN → 16-hex-char sha256 prefix.
  static String? hash(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(deviceId + _salt));
    return digest.toString().substring(0, 16);
  }
}
