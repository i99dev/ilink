import 'package:flutter/foundation.dart';

/// Tri-state per connectivity item.
///
/// Distinct from a plain bool because:
///   * `unknown` covers the cold-start window before the first poll
///     resolves — circles render as skeletons, not "OFF" (which would
///     misrepresent reality).
///   * `transitioning` covers the window between an optimistic UI
///     toggle and the next confirmed read — the ring color goes amber
///     so the user sees the action took.
enum NetState { on, off, unknown, transitioning }

/// Whole-network snapshot. One record fans out to N circles via
/// `select()` projections — see `connectivity_state_provider.dart`.
@immutable
class ConnectivityState {
  const ConnectivityState({
    required this.cellular,
    required this.roaming,
    required this.bluetooth,
    required this.wifi,
    required this.hotspot,
    this.wifiSsid,
    this.wifiRssi,
    this.btConnectedDevice,
    this.cellularGeneration,
  });

  /// Empty initial state — all `unknown`. Used as the seed before the
  /// first read resolves. Riverpod's AsyncValue.loading covers the
  /// outer "still fetching" wrapping; this is what consumers see when
  /// they `select()` into individual fields with a fallback.
  const ConnectivityState.unknown()
    : cellular = NetState.unknown,
      roaming = NetState.unknown,
      bluetooth = NetState.unknown,
      wifi = NetState.unknown,
      hotspot = NetState.unknown,
      wifiSsid = null,
      wifiRssi = null,
      btConnectedDevice = null,
      cellularGeneration = null;

  final NetState cellular;
  final NetState roaming;
  final NetState bluetooth;
  final NetState wifi;
  final NetState hotspot;

  /// `iPhone-Hotspot`, `BYD_Service` etc. Null when wifi off / not
  /// connected. Free-form — we don't parse SSID escape sequences.
  final String? wifiSsid;

  /// dBm. Null when wifi off.
  final int? wifiRssi;

  /// `Galaxy Buds`, etc. Null when no device connected.
  final String? btConnectedDevice;

  /// `4G`, `5G`, `LTE`. Null when not on cellular.
  final String? cellularGeneration;

  /// True iff at least one connectivity transport is live. Drives the
  /// outer ring color on the Network circle (green / amber / gray).
  bool get hasAnyOnline =>
      wifi == NetState.on ||
      cellular == NetState.on ||
      bluetooth == NetState.on;

  ConnectivityState copyWith({
    NetState? cellular,
    NetState? roaming,
    NetState? bluetooth,
    NetState? wifi,
    NetState? hotspot,
    Object? wifiSsid = _unset,
    Object? wifiRssi = _unset,
    Object? btConnectedDevice = _unset,
    Object? cellularGeneration = _unset,
  }) {
    return ConnectivityState(
      cellular: cellular ?? this.cellular,
      roaming: roaming ?? this.roaming,
      bluetooth: bluetooth ?? this.bluetooth,
      wifi: wifi ?? this.wifi,
      hotspot: hotspot ?? this.hotspot,
      wifiSsid: wifiSsid == _unset ? this.wifiSsid : wifiSsid as String?,
      wifiRssi: wifiRssi == _unset ? this.wifiRssi : wifiRssi as int?,
      btConnectedDevice: btConnectedDevice == _unset
          ? this.btConnectedDevice
          : btConnectedDevice as String?,
      cellularGeneration: cellularGeneration == _unset
          ? this.cellularGeneration
          : cellularGeneration as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectivityState &&
          other.cellular == cellular &&
          other.roaming == roaming &&
          other.bluetooth == bluetooth &&
          other.wifi == wifi &&
          other.hotspot == hotspot &&
          other.wifiSsid == wifiSsid &&
          other.wifiRssi == wifiRssi &&
          other.btConnectedDevice == btConnectedDevice &&
          other.cellularGeneration == cellularGeneration;

  @override
  int get hashCode => Object.hash(
    cellular,
    roaming,
    bluetooth,
    wifi,
    hotspot,
    wifiSsid,
    wifiRssi,
    btConnectedDevice,
    cellularGeneration,
  );

  @override
  String toString() =>
      'ConnectivityState(wifi=$wifi[$wifiSsid/$wifiRssi], '
      'cellular=$cellular[$cellularGeneration], '
      'roaming=$roaming, bt=$bluetooth[$btConnectedDevice], '
      'hotspot=$hotspot)';
}

const Object _unset = Object();
