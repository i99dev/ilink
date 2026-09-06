import '../../../kernel/shell/shell_command.dart';
import '../../../kernel/shell/shell_ops_coordinator.dart';
import '../domain/connectivity_state.dart';

/// Maps user intent to shell commands. Pure function from desired
/// state → ShellCommand. The writer doesn't dispatch — that's the
/// coordinator's job — so this is testable without a platform.
class ConnectivityWriter {
  ConnectivityWriter(this._coord);

  final ShellOpsCoordinator _coord;

  // Cache keys — match the readers in `connectivity_state_provider.dart`.
  static const _kWifiKey = 'dumpsys wifi';
  static const _kBtKey = 'dumpsys bluetooth_manager';
  static const _kCellKey = 'settings get global mobile_data';
  static const _kRoamingKey = 'settings get global data_roaming';
  static const _kHotspotKey = 'dumpsys wifi softap';

  Future<String> setWifi(NetState desired, {CancelToken? cancel}) {
    if (desired == NetState.on) {
      return _coord.write(
        const ShellCommand(['svc', 'wifi', 'enable']),
        invalidates: {_kWifiKey, _kHotspotKey},
        coalesceKey: _kWifiKey,
        cancel: cancel,
      );
    }
    if (desired == NetState.off) {
      return _coord.write(
        const ShellCommand(['svc', 'wifi', 'disable']),
        invalidates: {_kWifiKey, _kHotspotKey},
        coalesceKey: _kWifiKey,
        cancel: cancel,
      );
    }
    throw ArgumentError('setWifi only accepts on/off, got $desired');
  }

  Future<String> setBluetooth(NetState desired, {CancelToken? cancel}) {
    if (desired == NetState.on) {
      return _coord.write(
        const ShellCommand(['svc', 'bluetooth', 'enable']),
        invalidates: {_kBtKey},
        coalesceKey: _kBtKey,
        cancel: cancel,
      );
    }
    if (desired == NetState.off) {
      return _coord.write(
        const ShellCommand(['svc', 'bluetooth', 'disable']),
        invalidates: {_kBtKey},
        coalesceKey: _kBtKey,
        cancel: cancel,
      );
    }
    throw ArgumentError('setBluetooth only accepts on/off, got $desired');
  }

  /// Toggle cellular data via `settings put global mobile_data {0|1}`
  /// — the framework-level flag the modem stack honours.
  ///
  /// We deliberately do NOT use `svc data enable|disable` even though
  /// it looks more direct: `svc data` requires `MODIFY_PHONE_STATE`,
  /// which shell-uid doesn't hold on the BYD/Di5.x ROM, so writes
  /// silently no-op. Settings.Global has no such gate; verified
  /// round-trip on this car. The cache key + invalidates point at
  /// the new read source so a successful write retriggers the
  /// reader's next batch read.
  Future<String> setCellular(NetState desired, {CancelToken? cancel}) {
    final value = desired == NetState.on ? '1' : '0';
    return _coord.write(
      ShellCommand(['settings', 'put', 'global', 'mobile_data', value]),
      invalidates: {_kCellKey},
      coalesceKey: _kCellKey,
      cancel: cancel,
    );
  }

  Future<String> setRoaming(NetState desired, {CancelToken? cancel}) {
    final value = desired == NetState.on ? '1' : '0';
    return _coord.write(
      ShellCommand(['settings', 'put', 'global', 'data_roaming', value]),
      invalidates: {_kRoamingKey},
      coalesceKey: _kRoamingKey,
      cancel: cancel,
    );
  }

  /// Hotspot toggle is the most fragile — `cmd wifi start-softap`
  /// requires a SoftApConfiguration on Android 13+, and our adb-
  /// bootstrap shell may not have permission to construct one. The
  /// writer attempts the command; the controller falls back to an
  /// "open Android settings" intent if the shell write fails 3×.
  Future<String> setHotspot(NetState desired, {CancelToken? cancel}) {
    final argv = desired == NetState.on
        ? const ['cmd', 'wifi', 'start-softap']
        : const ['cmd', 'wifi', 'stop-softap'];
    return _coord.write(
      ShellCommand(argv),
      invalidates: {_kHotspotKey, _kWifiKey},
      coalesceKey: _kHotspotKey,
      cancel: cancel,
    );
  }
}
