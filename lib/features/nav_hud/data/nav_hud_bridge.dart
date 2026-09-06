import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart side of the `ilink/nav_hud` MethodChannel. Mirrors the Kotlin
/// `NavHudPlatformPlugin`: probe which cluster transports this car offers,
/// then arm/disarm the factory-cluster Nav-HUD and optionally pin a nav app.
///
/// The HUD itself runs entirely native (ingestion + transport on the
/// `nav-hud` thread); Dart only orchestrates lifecycle — it arms on the voice
/// "navigate" hand-off and disarms when navigation ends.
const MethodChannel _channel = MethodChannel('ilink/nav_hud');

/// Which cluster transports resolved as available on THIS car (the M0 probe).
class HudTransportProbe {
  const HudTransportProbe({required this.someip, required this.canfid});

  /// In-process SOME/IP — ADB-free.
  final bool someip;

  /// BYD instrument HAL via the privileged daemon — the reference-proven path.
  final bool canfid;

  bool get any => someip || canfid;

  /// True when the HUD can run with no ADB dependency at all.
  bool get adbFree => someip;

  static const HudTransportProbe none = HudTransportProbe(
    someip: false,
    canfid: false,
  );
}

/// The nav apps a frame can be sourced from.
enum NavApp { googleMaps, waze, yandex, amap }

String? _navAppKey(NavApp? a) => switch (a) {
  NavApp.googleMaps => 'google_maps',
  NavApp.waze => 'waze',
  NavApp.yandex => 'yandex',
  NavApp.amap => 'amap',
  null => null,
};

/// Thin, stateless wrapper over the channel. State lives in the controller.
class NavHudBridge {
  const NavHudBridge();

  Future<HudTransportProbe> probe() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('probe');
    if (m == null) return HudTransportProbe.none;
    return HudTransportProbe(
      someip: m['someip'] == true,
      canfid: m['canfid'] == true,
    );
  }

  Future<void> arm() => _channel.invokeMethod<void>('arm');

  Future<void> disarm() => _channel.invokeMethod<void>('disarm');

  /// Force a specific nav app onto the cluster; null = auto-arbitrate.
  Future<void> pin(NavApp? app) =>
      _channel.invokeMethod<void>('pin', {'source': _navAppKey(app)});

  /// Current option toggles (transliterate / cameraAlerts / amapWidget).
  Future<NavHudOptions> options() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('options');
    return NavHudOptions.fromMap(m);
  }

  Future<NavHudOptions> setOption(String key, bool value) async {
    final m = await _channel.invokeMapMethod<String, dynamic>('setOption', {
      'key': key,
      'value': value,
    });
    return NavHudOptions.fromMap(m);
  }

  /// Set the cluster-protocol override: `auto` / `someip` / `canfid`.
  Future<NavHudOptions> setClusterProtocol(String value) async {
    final m = await _channel.invokeMapMethod<String, dynamic>(
      'setClusterProtocol',
      {'value': value},
    );
    return NavHudOptions.fromMap(m);
  }

  /// Set the SOME/IP wire variant (`auto` / `ui7`). Unknown values are ignored
  /// natively. The revert path: `ui7` pins the wire to today's proven bytes.
  Future<NavHudOptions> setSomeIpVariant(String value) async {
    final m = await _channel.invokeMapMethod<String, dynamic>(
      'setSomeIpVariant',
      {'value': value},
    );
    return NavHudOptions.fromMap(m);
  }

  /// Live status — what the HUD is actually doing (transport, bind result,
  /// which app is driving, current maneuver). Polled while the panel is open.
  Future<NavHudStatus> status() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('status');
    return NavHudStatus.fromMap(m);
  }

  /// Push a synthetic maneuver through the live transport (cluster smoke test).
  Future<void> emitTest({int maneuver = 1, int distance = 200}) =>
      _channel.invokeMethod<void>('emitTest', {
        'maneuver': maneuver,
        'distance': distance,
      });
}

/// A snapshot of the running HUD (mirrors the native `status` map).
class NavHudStatus {
  const NavHudStatus({
    required this.armed,
    required this.transport,
    required this.connected,
    required this.pushed,
    required this.drivingApp,
    required this.maneuver,
    required this.distanceMeters,
    required this.road,
    this.rawManeuver,
  });

  final bool armed;

  /// "SOME_IP" / "CAN_FID" / null.
  final String? transport;

  /// Is the transport actually linked (SOME/IP bound)? The M0 signal.
  final bool connected;

  /// Frames pushed to the cluster so far (data flowing > 0).
  final int pushed;

  final String? drivingApp;
  final int? maneuver;
  final int? distanceMeters;
  final String? road;

  /// Diagnostics: the raw maneuver text the source read (before classification),
  /// so the UI/log can show exactly what each nav app exposed.
  final String? rawManeuver;

  static const NavHudStatus idle = NavHudStatus(
    armed: false,
    transport: null,
    connected: false,
    pushed: 0,
    drivingApp: null,
    maneuver: null,
    distanceMeters: null,
    road: null,
  );

  factory NavHudStatus.fromMap(Map<String, dynamic>? m) => m == null
      ? idle
      : NavHudStatus(
          armed: m['armed'] == true,
          transport: m['transport'] as String?,
          connected: m['connected'] == true,
          pushed: (m['pushed'] as num?)?.toInt() ?? 0,
          drivingApp: m['drivingApp'] as String?,
          maneuver: (m['maneuver'] as num?)?.toInt(),
          distanceMeters: (m['distanceMeters'] as num?)?.toInt(),
          road: m['road'] as String?,
          rawManeuver: m['rawManeuver'] as String?,
        );
}

/// The user-tunable Nav-HUD options (mirrors native NavHudOptions).
class NavHudOptions {
  const NavHudOptions({
    required this.transliterate,
    required this.cameraAlerts,
    required this.amapWidget,
    required this.autoStart,
    required this.clusterProtocol,
    required this.someIpVariant,
    required this.someIpVariantResolved,
  });

  final bool transliterate;
  final bool cameraAlerts;
  final bool amapWidget;

  /// Auto-arm the cluster HUD when voice navigation starts.
  final bool autoStart;

  /// Which cluster transport(s) to drive: `auto` (all available — default),
  /// `someip`, or `canfid`. Forces a single channel for diagnosis on trims where
  /// drive-all isn't right.
  final String clusterProtocol;

  /// SOME/IP wire variant: `auto` (derive from the detected model) or `ui7`
  /// (force today's on-car-proven wire). The stored preference — see
  /// [someIpVariantResolved] for what it actually resolves to.
  ///
  /// This is the sprint's revert switch: setting `ui7` pins the cluster wire to
  /// the bytes we ship today with no rebuild and no reinstall.
  final String someIpVariant;

  /// What [someIpVariant] resolves to right now, after the per-model default is
  /// applied. Always `ui7` today, including on undetected cars. Surfaced so the
  /// UI can show which variant `auto` actually picked.
  final String someIpVariantResolved;

  static const NavHudOptions defaults = NavHudOptions(
    transliterate: true,
    cameraAlerts: true,
    amapWidget: true,
    autoStart: true,
    clusterProtocol: 'auto',
    someIpVariant: 'auto',
    someIpVariantResolved: 'ui7',
  );

  factory NavHudOptions.fromMap(Map<String, dynamic>? m) => m == null
      ? defaults
      : NavHudOptions(
          transliterate: m['transliterate'] == true,
          cameraAlerts: m['cameraAlerts'] == true,
          amapWidget: m['amapWidget'] == true,
          autoStart: m['autoStart'] != false, // default true
          clusterProtocol: (m['clusterProtocol'] as String?) ?? 'auto',
          someIpVariant: (m['someIpVariant'] as String?) ?? 'auto',
          // Fall back to the proven wire, never to the raw pref: an older native
          // side that doesn't send this key must not make the UI claim `auto`
          // resolved to something it can't know.
          someIpVariantResolved:
              (m['someIpVariantResolved'] as String?) ?? 'ui7',
        );

  NavHudOptions copyWith({
    bool? transliterate,
    bool? cameraAlerts,
    bool? amapWidget,
    bool? autoStart,
    String? clusterProtocol,
    String? someIpVariant,
    String? someIpVariantResolved,
  }) => NavHudOptions(
    transliterate: transliterate ?? this.transliterate,
    cameraAlerts: cameraAlerts ?? this.cameraAlerts,
    amapWidget: amapWidget ?? this.amapWidget,
    autoStart: autoStart ?? this.autoStart,
    clusterProtocol: clusterProtocol ?? this.clusterProtocol,
    someIpVariant: someIpVariant ?? this.someIpVariant,
    someIpVariantResolved: someIpVariantResolved ?? this.someIpVariantResolved,
  );
}

final navHudBridgeProvider = Provider<NavHudBridge>(
  (ref) => const NavHudBridge(),
);
