import 'package:flutter/foundation.dart';

/// Runtime-resolved metadata for a target. Drives action eligibility
/// (Enable hides if `enabled`; Uninstall hides if `!canUninstall`;
/// Force-Stop hides if `runningTaskId == null`; Whitelist hides if
/// `inDozeWhitelist`).
///
/// Sourced from `pm`/`dumpsys` output for native apps; from the
/// mini-app catalog for mini-app targets.
@immutable
class AppMeta {
  const AppMeta({
    required this.targetKey,
    required this.enabled,
    required this.isSystem,
    required this.canUninstall,
    required this.inDozeWhitelist,
    this.runningTaskId,
    this.versionName,
    this.installerPackage,
    this.sizeBytes,
  });

  /// `packageName` for native, `appId` for mini-app — provider key.
  final String targetKey;

  /// True iff `pm dump <pkg> | grep enabled=true` returns true.
  /// Disabled apps are filtered out of the launcher already.
  final bool enabled;

  /// Pre-installed (`/system`, `/system_ext`, `/vendor`, `/product`).
  /// System apps can be `disable-user`d but not `pm uninstall --user 0`.
  final bool isSystem;

  /// True iff the OS allows user-level uninstall. False for system
  /// apps on AOSP (they need privileged access). The action registry
  /// uses this to hide the Uninstall circle on non-uninstallable apps.
  final bool canUninstall;

  /// True iff the package is on the doze whitelist. Drives the
  /// Whitelist action's eligibility (hide when already whitelisted).
  final bool inDozeWhitelist;

  /// When non-null, an ActivityTask is running for this app. Force-Stop
  /// only renders eligible when this is set. Used by Move (transfer
  /// running task) — `am stack move-task <taskId> <displayId>`.
  final int? runningTaskId;

  /// Human-readable version, e.g. "9.7.0" — surfaces in the sheet
  /// header beside the package name.
  final String? versionName;

  /// e.g. `com.android.vending` (Play Store), `com.android.shell`
  /// (sideloaded). Future use for Whitelist heuristics.
  final String? installerPackage;

  /// Sum of code + data + cache. Surfaces in the sheet header.
  final int? sizeBytes;

  /// Empty meta — used as the seed before the first read resolves.
  const AppMeta.unknown(this.targetKey)
    : enabled = true,
      isSystem = false,
      canUninstall = true,
      inDozeWhitelist = false,
      runningTaskId = null,
      versionName = null,
      installerPackage = null,
      sizeBytes = null;

  AppMeta copyWith({
    bool? enabled,
    bool? isSystem,
    bool? canUninstall,
    bool? inDozeWhitelist,
    Object? runningTaskId = _unset,
    Object? versionName = _unset,
    Object? installerPackage = _unset,
    Object? sizeBytes = _unset,
  }) {
    return AppMeta(
      targetKey: targetKey,
      enabled: enabled ?? this.enabled,
      isSystem: isSystem ?? this.isSystem,
      canUninstall: canUninstall ?? this.canUninstall,
      inDozeWhitelist: inDozeWhitelist ?? this.inDozeWhitelist,
      runningTaskId: runningTaskId == _unset
          ? this.runningTaskId
          : runningTaskId as int?,
      versionName: versionName == _unset
          ? this.versionName
          : versionName as String?,
      installerPackage: installerPackage == _unset
          ? this.installerPackage
          : installerPackage as String?,
      sizeBytes: sizeBytes == _unset ? this.sizeBytes : sizeBytes as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppMeta &&
          other.targetKey == targetKey &&
          other.enabled == enabled &&
          other.isSystem == isSystem &&
          other.canUninstall == canUninstall &&
          other.inDozeWhitelist == inDozeWhitelist &&
          other.runningTaskId == runningTaskId &&
          other.versionName == versionName &&
          other.installerPackage == installerPackage &&
          other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(
    targetKey,
    enabled,
    isSystem,
    canUninstall,
    inDozeWhitelist,
    runningTaskId,
    versionName,
    installerPackage,
    sizeBytes,
  );
}

const Object _unset = Object();
