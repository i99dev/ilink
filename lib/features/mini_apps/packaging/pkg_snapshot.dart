/// Data classes for the `pkg` family bridge contract.
///
/// Wire shape mirrors the SDK's `@ilink/sdk-types/src/pkg.ts`.
/// Keep field names stable — they cross JSON over the SDK bridge.
library;

class PackageSnapshot {
  const PackageSnapshot({
    required this.packageName,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.isSystem,
    this.iconHash,
  });

  /// Stable package id (`com.i99dev.ilink`).
  final String packageName;

  /// Human-readable label (localised by the host's current locale).
  final String label;
  final String versionName;
  final int versionCode;

  /// `true` when `ApplicationInfo.FLAG_SYSTEM` is set. Mini-apps can
  /// use this to filter out OEM stubs (preinstalled BYD apps,
  /// settings, etc.) from a launcher list.
  final bool isSystem;

  /// SHA-256 of the launcher icon's PNG bytes, or null when no icon
  /// can be fetched. The mini-app fetches the actual bytes via
  /// `pkg.icon({hash})` (Phase D) — the hash here is just a stable
  /// cache key.
  final String? iconHash;

  factory PackageSnapshot.fromMap(Map<String, Object?> m) => PackageSnapshot(
    packageName: m['packageName'] as String? ?? '',
    label: m['label'] as String? ?? '',
    versionName: m['versionName'] as String? ?? '',
    versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
    isSystem: m['isSystem'] as bool? ?? false,
    iconHash: m['iconHash'] as String?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'packageName': packageName,
    'label': label,
    'versionName': versionName,
    'versionCode': versionCode,
    'isSystem': isSystem,
    if (iconHash != null) 'iconHash': iconHash,
  };
}

class ForegroundPackage {
  const ForegroundPackage({
    required this.packageName,
    required this.activityClass,
    required this.atMillis,
  });

  final String packageName;

  /// `ComponentName.flattenToShortString()` of the foreground
  /// activity. May be empty if `getRunningTasks()` is unavailable.
  final String activityClass;

  /// `System.currentTimeMillis()` at the moment the host queried.
  /// The mini-app uses it to detect stale results during long polls.
  final int atMillis;

  factory ForegroundPackage.fromMap(Map<String, Object?> m) =>
      ForegroundPackage(
        packageName: m['packageName'] as String? ?? '',
        activityClass: m['activityClass'] as String? ?? '',
        atMillis: (m['atMillis'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'packageName': packageName,
    'activityClass': activityClass,
    'atMillis': atMillis,
  };
}

class UsageRow {
  const UsageRow({
    required this.packageName,
    required this.totalTimeInForegroundMs,
    required this.lastTimeUsedMs,
  });

  final String packageName;
  final int totalTimeInForegroundMs;
  final int lastTimeUsedMs;

  factory UsageRow.fromMap(Map<String, Object?> m) => UsageRow(
    packageName: m['packageName'] as String? ?? '',
    totalTimeInForegroundMs:
        (m['totalTimeInForegroundMs'] as num?)?.toInt() ?? 0,
    lastTimeUsedMs: (m['lastTimeUsedMs'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'packageName': packageName,
    'totalTimeInForegroundMs': totalTimeInForegroundMs,
    'lastTimeUsedMs': lastTimeUsedMs,
  };
}

/// Phase D: response shape for `pkg.icon`. The host renders the
/// launcher icon to a 96 px PNG and base64-encodes it for the bridge
/// hop (no binary frames over MethodChannel). Mini-apps receive the
/// bytes as a `data:image/png;base64,…` URL via the SDK shim.
///
/// Failure mode: `ok == false` with `error` set (uninstalled package,
/// drawable lookup fails, render OOM). The mini-app falls back to
/// the first-letter tile in that case.
class PkgIconResult {
  const PkgIconResult({required this.ok, this.pngBase64, this.error});

  final bool ok;

  /// Base64-encoded PNG bytes (no line wrap). Always paired with
  /// `ok == true`; null on failure.
  final String? pngBase64;
  final String? error;

  factory PkgIconResult.fromMap(Map<String, Object?> m) => PkgIconResult(
    ok: m['ok'] as bool? ?? false,
    pngBase64: m['pngBase64'] as String?,
    error: m['error'] as String?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    if (pngBase64 != null) 'pngBase64': pngBase64,
    if (error != null) 'error': error,
  };
}

/// One row from `pkg.running` — a task currently sitting on a display.
/// Same shape as the Kotlin `TaskRow` minus host-only fields. The
/// running-apps controller groups these by `displayId` to feed the
/// per-display chip strip and the bottom-corner activity sheet.
class RunningTask {
  const RunningTask({
    required this.taskId,
    required this.rootTaskId,
    required this.displayId,
    required this.packageName,
    required this.isForeground,
  });

  final int taskId;
  final int rootTaskId;
  final int displayId;
  final String packageName;
  final bool isForeground;

  factory RunningTask.fromMap(Map<String, Object?> m) => RunningTask(
    taskId: (m['taskId'] as num?)?.toInt() ?? -1,
    rootTaskId: (m['rootTaskId'] as num?)?.toInt() ?? -1,
    displayId: (m['displayId'] as num?)?.toInt() ?? -1,
    packageName: m['packageName'] as String? ?? '',
    isForeground: m['isForeground'] as bool? ?? false,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'taskId': taskId,
    'rootTaskId': rootTaskId,
    'displayId': displayId,
    'packageName': packageName,
    'isForeground': isForeground,
  };
}

class LaunchResult {
  const LaunchResult({required this.ok, required this.path, this.error});

  final bool ok;

  /// Which path the host took:
  ///   * `am-start` — `am start --display N`
  ///   * `am-start-rePinned` — `am start --display N` initially
  ///     bounced to another display (typically 0) for a known-bouncy
  ///     package (Waze, Google Maps, Spotify, YouTube, …); host
  ///     auto-recovered via `am stack move-task`. App is on the
  ///     requested display. Indistinguishable to the user from a
  ///     normal launch; surfaced separately so observability can
  ///     track bounce-rate regressions per ROM.
  ///   * `am-start-bounced` — bounced AND the rePin failed. App is
  ///     on the wrong display. Mini-apps should treat this like
  ///     `ok=false` and offer the user a fallback (e.g. open on
  ///     IVI instead).
  ///   * `intent-launch` — `Context.startActivity` (default display)
  ///   * `move-task` — `pkg.move` succeeded, or `pkg.launch` resolver
  ///     picked the Migrate branch (existing task on another display).
  ///   * `move-task-front` — `pkg.launch` resolver picked the Resume
  ///     branch: package already had a task on the target display, so
  ///     we brought it to front instead of spawning a fresh task. Fix
  ///     for the "re-tapping launch spawns a new instance" bug.
  ///   * `dishare-quickshare` / `dishare-quickshare-cached` — DiShare
  ///     transport committed via the `quickShare` op (or short-
  ///     circuited because the same package is already mirrored on
  ///     the same target tag). Same `ok=true` outcome.
  ///   * `no-op` — `pkg.move` was redundant (already on target).
  ///   * `denied` — package not launchable (no LAUNCHER intent), or
  ///     the host doesn't have permission for the requested display.
  final String path;
  final String? error;

  /// True when the host's `am ...` shell hit the BYD WMS
  /// `ClassCastException: ActivityRecord cannot be cast to Task`
  /// transient family even after the in-host retry exhausted. The
  /// caller should surface a Retry affordance to the user — a
  /// fresh attempt 0.5–1 s later usually succeeds because the WMS
  /// state has settled. Derived from `path` so the wire shape stays
  /// a pure map and we don't have a redundant boolean to maintain.
  bool get wmsTransient =>
      path == 'wms_transient' ||
      path == 'am-start-bounced-wms-transient' ||
      path == 'tour_marker_wms_transient';

  factory LaunchResult.fromMap(Map<String, Object?> m) => LaunchResult(
    ok: m['ok'] as bool? ?? false,
    path: m['path'] as String? ?? 'denied',
    error: m['error'] as String?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'path': path,
    if (error != null) 'error': error,
  };
}

/// Outcome of a `pkg.tourMarker` invocation. Wider than a plain
/// `bool` so the calibration tour can distinguish a recoverable
/// WMS transient (offer Retry) from a hard failure (offer Skip
/// this display).
class TourMarkerResult {
  const TourMarkerResult({
    required this.ok,
    this.errorCode,
    this.error,
    this.wmsTransient = false,
  });

  final bool ok;

  /// Stable error code from the host, e.g. `tour_marker_wms_transient`
  /// or `tour_marker_failed`. Null on success.
  final String? errorCode;

  /// Human-readable error message (already truncated host-side).
  final String? error;

  /// True iff [errorCode] indicates the BYD WMS transient family.
  /// Drives the "show Retry button" branch in the probing card.
  final bool wmsTransient;

  factory TourMarkerResult.ok() => const TourMarkerResult(ok: true);

  factory TourMarkerResult.failure({
    required String errorCode,
    String? error,
  }) => TourMarkerResult(
    ok: false,
    errorCode: errorCode,
    error: error,
    wmsTransient: errorCode == 'tour_marker_wms_transient',
  );
}
