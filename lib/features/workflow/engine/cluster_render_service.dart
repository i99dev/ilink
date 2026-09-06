/// Renders a workflow's cluster-output step to the instrument cluster —
/// the SAFE way (plan §7).
///
/// Always goes through the host `surface.*` family ([SurfaceNativeBridge])
/// — NEVER a raw `am start` / `move-task` (the documented, reverted L7
/// fission hang). The driver display is resolved per-trim; the renderer
/// gracefully skips when there's no cluster or no cluster-render bundle.
///
/// Safety:
///   * TRANSIENT renders auto-tear-down after `ttlMs`.
///   * PERSISTENT takeover is stationary-gated at activation (a cluster
///     takeover pins the priority slot + evicts nav — dangerous mid-trip)
///     and limited to ONE workflow-owned surface per car (a new persistent
///     render destroys the prior). Auto-teardown-off-Park is a documented
///     follow-up.
///
/// Deps are injected so this unit-tests without the platform channels.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mini_apps/runtime/surface_native_bridge.dart';

/// The installed cluster-render mini-app the surface mounts (its `appId`
/// + local `bundleUri`). Null when no such bundle is installed → skip.
typedef ClusterAppRef = ({String appId, String bundleUri});

class ClusterRenderService {
  ClusterRenderService({
    required SurfaceNativeBridge surface,
    required Future<int?> Function() resolveClusterDisplayId,
    required Future<ClusterAppRef?> Function() resolveClusterApp,
    required Future<int?> Function() readSpeed,
    DateTime Function()? clock,
  }) : _surface = surface,
       _resolveDisplayId = resolveClusterDisplayId,
       _resolveApp = resolveClusterApp,
       _readSpeed = readSpeed,
       _now = clock ?? DateTime.now;

  static const int _stationarySpeedLimit = 5;

  final SurfaceNativeBridge _surface;
  final Future<int?> Function() _resolveDisplayId;
  final Future<ClusterAppRef?> Function() _resolveApp;
  final Future<int?> Function() _readSpeed;
  final DateTime Function() _now;

  /// The single workflow-owned persistent surface (one per car).
  String? _persistentSurfaceId;
  Timer? _transientTimer;

  /// Render a cluster-output step. [args] is the node config
  /// (`route`, `mode`, `ttlMs`, …). Returns `{ok}` / `{error}` —
  /// matching the engine's other dispatchers.
  Future<Map<String, Object?>> render(
    String route,
    Map<String, Object?> args,
  ) async {
    final mode = (args['mode'] as String?) ?? 'transient';

    // PERSISTENT takeover is dangerous mid-trip — block while moving.
    if (mode == 'persistent') {
      final speed = await _readSpeed();
      if (speed != null && speed > _stationarySpeedLimit) {
        debugPrint(
          '[workflow] cluster persistent render blocked: moving ($speed km/h)',
        );
        return {'error': 'unsafe_while_moving'};
      }
    }

    final displayId = await _resolveDisplayId();
    if (displayId == null) {
      debugPrint(
        '[workflow] cluster render skipped: no cluster display on this trim',
      );
      return {'error': 'no_cluster_display'};
    }
    final app = await _resolveApp();
    if (app == null) {
      debugPrint(
        '[workflow] cluster render skipped: no cluster-render bundle installed',
      );
      return {'error': 'no_cluster_bundle'};
    }

    try {
      // One persistent surface per car: tear the prior down first.
      if (mode == 'persistent' && _persistentSurfaceId != null) {
        await _destroy(_persistentSurfaceId!);
        _persistentSurfaceId = null;
      }
      final result = await _surface.create(
        displayId: displayId,
        appId: app.appId,
        bundleUri: app.bundleUri,
        route: route,
      );
      final surfaceId = result.surfaceId;
      if (mode == 'persistent') {
        _persistentSurfaceId = surfaceId;
      } else {
        // Transient — auto-tear-down after the TTL (default 30 s).
        final ttlMs = (args['ttlMs'] as num?)?.toInt() ?? 30000;
        _transientTimer?.cancel();
        _transientTimer = Timer(Duration(milliseconds: ttlMs), () {
          _destroy(surfaceId);
        });
      }
      return {
        'ok': true,
        'surfaceId': surfaceId,
        'at': _now().toIso8601String(),
      };
    } catch (e) {
      debugPrint('[workflow] cluster render failed: $e');
      return {'error': e.toString()};
    }
  }

  Future<void> _destroy(String surfaceId) async {
    try {
      await _surface.destroy(surfaceId: surfaceId);
    } catch (e) {
      debugPrint('[workflow] cluster surface destroy failed: $e');
    }
  }

  void dispose() {
    _transientTimer?.cancel();
  }
}
