import 'package:flutter/foundation.dart';

@immutable
class ReleaseManifest {
  const ReleaseManifest({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.signerSha256,
    required this.forceUpdate,
    required this.releasedAt,
    this.minSupportedVersionCode,
    this.releaseNotes,
    this.package,
  });

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String sha256;
  final int sizeBytes;
  final String signerSha256;
  final bool forceUpdate;
  final DateTime releasedAt;
  final int? minSupportedVersionCode;
  final String? releaseNotes;

  /// Expected Android package identity for this dashboard update.
  final String? package;

  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    return ReleaseManifest(
      versionCode: json['versionCode'] as int,
      versionName: json['versionName'] as String,
      apkUrl: json['apkUrl'] as String,
      sha256: json['sha256'] as String,
      sizeBytes: json['sizeBytes'] as int,
      signerSha256: json['signerSha256'] as String,
      forceUpdate: json['forceUpdate'] as bool? ?? false,
      releasedAt: DateTime.parse(json['releasedAt'] as String),
      minSupportedVersionCode: json['minSupportedVersionCode'] as int?,
      releaseNotes: json['releaseNotes'] as String?,
      package: json['package'] as String?,
    );
  }

  bool isNewerThan(int currentVersionCode) => versionCode > currentVersionCode;

  // Force is required if the installed version falls below the support floor
  // or the server explicitly demands it.
  bool requiresForceUpdate(int currentVersionCode) {
    final belowFloor =
        minSupportedVersionCode != null &&
        currentVersionCode < minSupportedVersionCode!;
    return forceUpdate || belowFloor;
  }
}
