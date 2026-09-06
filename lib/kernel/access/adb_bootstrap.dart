import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Surface for the native [AdbBootstrap] state machine. Cold launch
/// already self-runs the grant set on a daemon thread; this wrapper
/// exists so the onboarding screen can detect the case where
/// Wireless debugging wasn't enabled yet at first launch
/// ([AdbBootstrapResultKind.skipped]) and offer a retry button.
///
/// Channel contract — see `AdbBootstrapPlugin.kt`:
///   * `getStatus` → `Map<String, dynamic>`. Cheap, read-only.
///   * `retry` → drops the persisted version + re-runs the full grant
///     set on a worker thread. Returns the same status map. Can take
///     several seconds; UI must show a spinner.
///
/// Lifecycle scope of the onboarding integration: the wireless-
/// debugging tile is shown only on the onboarding screen which fires
/// once per install. If the user later disables Wireless debugging
/// from system settings the bootstrap retries on every cold launch
/// (Skipped is non-terminal — version stays at 0 / pre-target until
/// the next successful run). For *forced* retries after onboarding
/// completes, surface the controller through a dev-tools button or a
/// settings tile; do not auto-prompt.
class AdbBootstrapChannel {
  AdbBootstrapChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_kChannelName);

  static const _kChannelName = 'ilink/adb_bootstrap';

  final MethodChannel _channel;

  /// Read the persisted-version + last-result snapshot. Returns
  /// [AdbBootstrapStatus.unknown] if the platform side is unreachable
  /// (iOS / web / a build where the plugin wasn't registered).
  Future<AdbBootstrapStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('getStatus');
      if (raw == null) return const AdbBootstrapStatus.unknown();
      return AdbBootstrapStatus.fromMap(raw);
    } on MissingPluginException {
      return const AdbBootstrapStatus.unknown();
    } on PlatformException {
      return const AdbBootstrapStatus.unknown();
    }
  }

  /// Drop the persisted version and re-run the bootstrap. Used when
  /// the user has just enabled Wireless debugging from the onboarding
  /// instructions. Returns the resulting status snapshot.
  Future<AdbBootstrapStatus> retry() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('retry');
    if (raw == null) return const AdbBootstrapStatus.unknown();
    return AdbBootstrapStatus.fromMap(raw);
  }
}

/// What [AdbBootstrap] reported on its most recent run.
enum AdbBootstrapResultKind {
  /// No run has happened yet — process started but the daemon thread
  /// hasn't reached `runIfNeeded`. Treat as "wait a bit".
  unknown,

  /// Persisted version >= target version. Nothing to do.
  alreadyApplied,

  /// All grant commands ran without an error string.
  applied,

  /// ADB bridge wasn't reachable. Most common cause: user hasn't
  /// flipped Wireless debugging on yet. Trigger the retry path after
  /// they do.
  skipped,

  /// At least one grant command came back with an error string.
  /// `lastResultDetail` carries the first failure for diagnostics.
  failed,
}

class AdbBootstrapStatus {
  const AdbBootstrapStatus({
    required this.persistedVersion,
    required this.targetVersion,
    required this.lastResult,
    this.detail,
    this.failureCount = 0,
  });

  const AdbBootstrapStatus.unknown()
    : persistedVersion = 0,
      targetVersion = 0,
      lastResult = AdbBootstrapResultKind.unknown,
      detail = null,
      failureCount = 0;

  factory AdbBootstrapStatus.fromMap(Map<String, Object?> map) {
    return AdbBootstrapStatus(
      persistedVersion: map['persistedVersion'] as int? ?? 0,
      targetVersion: map['targetVersion'] as int? ?? 0,
      lastResult: _kindFromString(map['lastResultKind'] as String?),
      detail: map['lastResultDetail'] as String?,
      failureCount: map['lastFailureCount'] as int? ?? 0,
    );
  }

  final int persistedVersion;
  final int targetVersion;
  final AdbBootstrapResultKind lastResult;
  final String? detail;
  final int failureCount;

  /// True when the device is fully provisioned at the current target
  /// version. Onboarding hides the wireless-debugging tile in this state.
  bool get isApplied =>
      persistedVersion >= targetVersion &&
      (lastResult == AdbBootstrapResultKind.alreadyApplied ||
          lastResult == AdbBootstrapResultKind.applied);

  /// True when ADB couldn't be reached. The onboarding tile renders
  /// the "enable Wireless debugging" instructions in this state.
  bool get needsWirelessDebugging =>
      lastResult == AdbBootstrapResultKind.skipped;

  /// True when at least one grant failed. Onboarding renders a
  /// diagnostic with [detail] in this state.
  bool get hasFailures =>
      lastResult == AdbBootstrapResultKind.failed && failureCount > 0;

  static AdbBootstrapResultKind _kindFromString(String? s) => switch (s) {
    'alreadyApplied' => AdbBootstrapResultKind.alreadyApplied,
    'applied' => AdbBootstrapResultKind.applied,
    'skipped' => AdbBootstrapResultKind.skipped,
    'failed' => AdbBootstrapResultKind.failed,
    _ => AdbBootstrapResultKind.unknown,
  };
}

/// Singleton channel handle.
final adbBootstrapChannelProvider = Provider<AdbBootstrapChannel>((_) {
  return AdbBootstrapChannel();
});

/// Live status stream. Refetched whenever a consumer calls
/// `ref.invalidate(adbBootstrapStatusProvider)` — e.g. after the user
/// taps the retry button and we want to repaint the tile.
final adbBootstrapStatusProvider = FutureProvider<AdbBootstrapStatus>((
  ref,
) async {
  return ref.read(adbBootstrapChannelProvider).getStatus();
});
