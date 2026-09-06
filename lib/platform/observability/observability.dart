/// Local diagnostics compatibility facade. No analytics SDK, identifier
/// collection, remote transport, DSN or opt-in path exists in this build.
library;

import 'package:flutter/foundation.dart';
import 'gate_diagnostics.dart';
export 'gate_diagnostics.dart';

class Observability {
  Observability._();
  static bool get isEnabled => false;
  static Future<void> runApp(Future<void> Function() body) => body();
  static void breadcrumb({
    required String category,
    required String message,
    Map<String, Object?>? data,
    Object? level,
  }) {}
  static void setVehicleContext({
    String? headUnit,
    String? region,
    String? deviceId,
  }) {}
  static void setChassisVinContext({String? vinRaw}) {}
  static void setTrimContext({
    String? variant,
    required String dilinkFamily,
    String? friendlyName,
    String? bydCarType,
    String? brand,
    int? vehicleId,
    bool? clusterAvailable,
  }) {}
  static void setAccountContext({
    bool? paired,
    String? tier,
    bool? isDeveloper,
  }) {}
  static void setActiveMiniApp({required String appId, String? version}) {}
  static void clearActiveMiniApp() {}
  static void logGateReject(GateDiagnostics d) {}
  static Future<void> logDisplayClassified({
    required String name,
    required int widthPx,
    required int heightPx,
    required int displayId,
    required String role,
    required String source,
    required String confidence,
    required bool markerPresent,
    String? dimReason,
    String? variantId,
    String? dilinkFamily,
    String? locale,
  }) async {}
  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? hint,
  }) async {
    if (kDebugMode) debugPrint('Local diagnostic: ${error.runtimeType}');
  }

  static const String _redactMarker = '[REDACTED:miniapp]';

  /// Patterns whose presence in any string causes the whole string to
  /// be redacted. Append-only — every entry maps to a real IP-bearing
  /// substring that, if leaked via a Sentry event, would defeat one of
  /// the encrypted-table payloads.
  static final List<Pattern> _redactPatterns = <Pattern>[
    // Op tokens — exactly 16 lowercase hex chars. Every entry in
    // tool/mini_app_op_index.txt produces one of these; appearing in
    // a Sentry message would reveal we're looking up that op.
    RegExp(r'\b[a-f0-9]{16}\b'),
    // The op-token salt prefix. If anyone logs the input that produced
    // a token, this is the giveaway.
    'mini_app_op:',
    // Shell-command shapes from the encrypted textproto. Each is a
    // distinctive string only a host with our approach would emit.
    'am start-activity --activity-multiple-task',
    'am stack move-task',
    'am stack list',
    'am force-stop com.example.amapservice',
    // BYD's bundled cluster-slot package name. Naming it specifically
    // is the "we know how their cluster slot is wired" signal.
    'com.example.amapservice',
    // Our placeholder activity that seeds an empty stack on the
    // target display before stack move-task.
    'com.i99dev.ilink/.display.ClusterActivity',
    // Display.name markers for BYD's cluster slots — heuristic
    // substrings the display family matches.
    'XDJAScreenProjection',
    // input -d N tap/swipe — gesture family's ADB fallback.
    RegExp(r'\binput -d \d+\b'),
    // Mini-app op family namespaces. If a breadcrumb leaks "pkg.launch"
    // verbatim, the scrubber catches it before it ships.
    'pkg.launch_on_display',
    'pkg.stack_list',
    'pkg.stack_move_task',
    'surface.am_start_cluster',
    'surface.amap_force_stop',
    'gesture.input_tap',
    'gesture.input_swipe',
    'display.cluster_name_marker',
    'display.amap_slot_marker',
  ];

  static String _scrubString(String s) {
    for (final p in _redactPatterns) {
      if (p is RegExp ? p.hasMatch(s) : s.contains(p as String)) {
        return _redactMarker;
      }
    }
    return s;
  }

  static String debugScrub(String value) => _scrubString(value);
}
