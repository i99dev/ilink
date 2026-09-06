import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/sdk/_internal/logger.dart';

/// Snapshot of every Android-side privilege iLINK needs to act as a
/// viable BYD-launcher replacement. Read-only; granting lives in the
/// upcoming bootstrap dispatcher (Phase L2).
///
/// All fields default to `false` — a missing channel response (older
/// APK on the HU, plugin not installed yet, etc.) reads as "nothing
/// granted" rather than crashing the Diagnostics view.
class LauncherPrivilegeStatus {
  const LauncherPrivilegeStatus({
    this.writeSecureSettings = false,
    this.readLogs = false,
    this.packageUsageStats = false,
    this.systemAlertWindow = false,
    this.ignoreBatteryOptimizations = false,
    this.isDefaultHome = false,
    this.remoteControlA11yEnabled = false,
    this.watchdogA11yEnabled = false,
    this.homeAliasEnabled = false,
  });

  /// Privileged perm. `pm grant`-only; AdbBootstrap already handles
  /// this for the existing accessibility-services bootstrap path.
  final bool writeSecureSettings;

  /// Privileged perm. Earmarked for the launcher-mode logcat tail
  /// surface in the upcoming Diagnostics view.
  final bool readLogs;

  /// Special-access (appop, not perm). Lets us read recent-app
  /// activity without spelunking through `dumpsys`.
  final bool packageUsageStats;

  /// Special-access. Required for the floating chat-head and any
  /// Phase-A overlay surfaces. Already managed by AdbBootstrap.
  final bool systemAlertWindow;

  /// Special-access. Lets the foreground service stay alive while
  /// idle on the home screen — required when iLINK IS the home.
  final bool ignoreBatteryOptimizations;

  /// Whether the system currently resolves the HOME intent to us.
  /// `false` is the default state on a fresh install — the user has
  /// to opt in via the launcher-mode picker.
  final bool isDefaultHome;

  /// Whether the user has enabled the gesture-dispatch a11y service
  /// in the system a11y panel. Required for cluster-input forwarding
  /// even when launcher mode is off; surfacing here lets one screen
  /// answer "is everything wired?" instead of two.
  final bool remoteControlA11yEnabled;

  /// Watchdog companion service to [remoteControlA11yEnabled] —
  /// detects when BYD's a11y panel has silently disabled the gesture
  /// service.
  final bool watchdogA11yEnabled;

  /// Whether the launcher-mode HOME activity-alias is currently
  /// enabled in PackageManager. Distinct from [isDefaultHome]:
  ///   * `homeAliasEnabled = false, isDefaultHome = false`
  ///     — user has not opted into launcher mode.
  ///   * `homeAliasEnabled = true,  isDefaultHome = false`
  ///     — opted in but the system home picker has not been resolved
  ///     to us yet (user closed the picker without choosing, or
  ///     another launcher won).
  ///   * `homeAliasEnabled = true,  isDefaultHome = true`
  ///     — fully active.
  final bool homeAliasEnabled;

  factory LauncherPrivilegeStatus.fromMap(Map<dynamic, dynamic> raw) {
    bool b(String key) => raw[key] == true;
    return LauncherPrivilegeStatus(
      writeSecureSettings: b('writeSecureSettings'),
      readLogs: b('readLogs'),
      packageUsageStats: b('packageUsageStats'),
      systemAlertWindow: b('systemAlertWindow'),
      ignoreBatteryOptimizations: b('ignoreBatteryOptimizations'),
      isDefaultHome: b('isDefaultHome'),
      remoteControlA11yEnabled: b('remoteControlA11yEnabled'),
      watchdogA11yEnabled: b('watchdogA11yEnabled'),
      homeAliasEnabled: b('homeAliasEnabled'),
    );
  }

  /// Number of granted items out of the total tracked. Used by the
  /// status row to show "n of 9 OK" without each call site doing
  /// the arithmetic.
  int get grantedCount {
    var n = 0;
    if (writeSecureSettings) n++;
    if (readLogs) n++;
    if (packageUsageStats) n++;
    if (systemAlertWindow) n++;
    if (ignoreBatteryOptimizations) n++;
    if (isDefaultHome) n++;
    if (remoteControlA11yEnabled) n++;
    if (watchdogA11yEnabled) n++;
    if (homeAliasEnabled) n++;
    return n;
  }

  static const int totalCount = 9;
}

/// Single entry point to the Kotlin-side probe. The channel name
/// matches `LauncherPrivilegePlugin.CHANNEL`.
class LauncherPrivilegeChannel {
  const LauncherPrivilegeChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_kChannel);

  static const _kChannel = 'ilink/launcher_privilege';
  static const _log = Logger('LauncherPrivilege');

  final MethodChannel _channel;

  /// Fetch the current privilege snapshot. Returns the
  /// all-`false` default on channel error so the Diagnostics view
  /// always renders something; the underlying error is logged for
  /// triage rather than thrown to the UI.
  Future<LauncherPrivilegeStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
      if (raw == null) return const LauncherPrivilegeStatus();
      return LauncherPrivilegeStatus.fromMap(raw);
    } on PlatformException catch (e) {
      _log.w('status probe failed: ${e.code} ${e.message}');
      return const LauncherPrivilegeStatus();
    } on MissingPluginException {
      // Older APK on the HU, dev-fast-replace, or test harness without
      // the plugin registered. Surface as "nothing granted" so the UI
      // still renders.
      return const LauncherPrivilegeStatus();
    }
  }
}

/// Process-wide singleton so tests can override the channel via
/// `overrideWithValue(LauncherPrivilegeChannel(channel: fake))`.
final launcherPrivilegeChannelProvider = Provider<LauncherPrivilegeChannel>(
  (ref) => const LauncherPrivilegeChannel(),
);

/// Reactive snapshot of launcher-mode privileges. Re-fetches on
/// invalidate (the bootstrap dispatcher invalidates this after each
/// grant attempt to refresh the UI). Async because the MethodChannel
/// call is async — but the underlying probe is cheap so this typically
/// settles within one frame.
///
/// `.autoDispose` because the only consumer is the Diagnostics card —
/// when the user closes Diagnostics the cached snapshot is no longer
/// useful, and re-opening triggers a fresh probe (which is what we
/// want on a hot-reinstall when grants may have changed).
final launcherPrivilegeStatusProvider =
    FutureProvider.autoDispose<LauncherPrivilegeStatus>((ref) async {
      final channel = ref.watch(launcherPrivilegeChannelProvider);
      return channel.status();
    });
