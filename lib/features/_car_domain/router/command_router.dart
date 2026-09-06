import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../sdk/car/_transport/car_bridge.dart';
import '../../../sdk/car/car_caller.dart';
import '../../../sdk/car/client.dart';
import 'package:ilink/sdk/car/identity/car_profile.dart';
import 'package:ilink/sdk/car/identity/car_identity_provider.dart';
import '../command/registry.dart';
import '../safety/rate_limiter.dart';
import '../safety/security_bridge.dart';

/// Dispatches commands coming in from the tunnel (WebSocket) into either
/// the typed command registry or the raw CarBridge surface. Keep wire
/// compatibility with older backend action ids by preserving `run_action`,
/// `run_unit`, `ac_transact`, `get_status` / `car_all_status`.
class CarCommandRouter {
  CarCommandRouter(this.ref);
  final Ref ref;

  /// Speed (km/h) above which commands flagged [CarCommand.requiresStationary]
  /// are refused. 5 km/h matches "at parking / crawl speed" — tolerant of
  /// speed-sensor noise at a dead stop while still blocking highway use.
  static const int _stationarySpeedLimit = 5;

  /// Vehicle-speed signal the stationary gate reads.
  static const String _speedSignal = 'Statistic.STATISTIC_SPEED_SIG_VDIS';

  /// A cached speed younger than this is trusted as-is (skip the live read).
  /// Above it we force a fresh read — see [resolveStationaryGateSpeed].
  static const Duration _speedTrustWindow = Duration(seconds: 3);

  /// Bound on the gate's live speed read. The daemon is normally reachable
  /// right when a command is dispatched (the command itself goes there); if
  /// it isn't, we don't stall the user — we fail open (the actual actuation
  /// then fails on its own, so nothing unsafe happens).
  static const Duration _speedReadTimeout = Duration(milliseconds: 1200);

  /// Effective speed (km/h) for gating a `requiresStationary` command, or
  /// null when no trustworthy reading is available.
  ///
  /// **Why this isn't just `client.value(speed)`:** brands that push deltas
  /// (BYD) can MISS the "now stopped" frame, leaving a stale "moving" value
  /// in the cache — which wrongly blocked a PARKED car from opening a window
  /// (the reported bug). A freshness check alone can't fix it either, because
  /// at constant cruise speed there are also few deltas, so a stale value can
  /// be genuinely moving. So we get GROUND TRUTH: trust the cache only when
  /// it's very fresh, otherwise force a live read.
  ///
  /// Returns null (→ caller allows, matching the pre-existing "signal
  /// unavailable → allow") when the live read fails: a dead daemon means the
  /// actuation itself will fail, so failing the gate open is safe.
  @visibleForTesting
  static Future<int?> resolveStationaryGateSpeed(CarClient client) async {
    final age = client.freshness(_speedSignal);
    if (age != null && age <= _speedTrustWindow) {
      return client.value(_speedSignal);
    }
    try {
      return await client.refreshValue(_speedSignal).timeout(_speedReadTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> dispatch(
    String action,
    Map<String, dynamic> payload, {

    /// Caller identity — typed [CarConsumer] for app callsites,
    /// accepted as the SDK's narrower [CarCaller] so the SDK never
    /// needs to import the app's full consumer hierarchy.
    /// Optional during F3 migration; new code should always pass a
    /// typed value so the audit log can attribute the dispatch.
    CarCaller? caller,
  }) async {
    final started = DateTime.now();
    final result = await _dispatchInner(action, payload);
    // Emit the post-dispatch log line whatever the outcome. `ok` is derived
    // from the presence of an `error` key so gated rejections (rate limit,
    // integrity, stationary) also get recorded — those are signal too.
    final outcome = _outcomeCode(result);
    unawaited(
      ref
          .read(securityBridgeProvider)
          .logDispatch(
            commandId: action,
            args: payload,
            outcome: outcome,
            latency: DateTime.now().difference(started),
            caller: caller?.kindLabel,
          ),
    );
    return result;
  }

  Future<Map<String, dynamic>> _dispatchInner(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final security = ref.read(securityBridgeProvider);
    try {
      // Integrity gate: if the monitor has already flipped unhealthy, stop
      // dispatching. Fail-closed on known tamper; fail-open on channel
      // errors is handled inside [SecurityBridge.integrityHealthy].
      if (!await security.integrityHealthy()) {
        return const {
          'error': 'integrity check failed',
          'code': 'INTEGRITY_UNHEALTHY',
        };
      }
      // CarProfile fast-deny — fold the static action-support map
      // before rate-limiting. When the active CarProfile says the
      // action is UNSUPPORTED on this trim AND the profile is NOT a
      // fallback (i.e. we're confident in the answer), bail with a
      // typed code BEFORE burning a rate-limit slot or paying the
      // bridge round-trip. ~200 ms saved per known-bad call.
      //
      // When the profile IS a fallback, we let the daemon stay
      // authoritative — the speed win isn't worth blocking a
      // working actuator on an unknown sub-trim. See
      // `feedback_detect_dilink_not_just_trim` and
      // [CarActionSupport]'s class breakdown for the rationale.
      final profileSnapshot = ref.read(carProfileProvider).value;
      if (profileSnapshot != null && !profileSnapshot.isFallback) {
        final support = profileSnapshot.supportFor(action);
        if (support == CarActionSupport.unsupported) {
          return {
            'error': 'action not supported on this car',
            'code': 'ACTION_UNSUPPORTED',
            'profileKey': profileSnapshot.key.toJson(),
            'friendlyName': profileSnapshot.friendlyName,
          };
        }
      }
      // Resolve the registry entry before rate-limiting so an explicit
      // `rateClass` on the command overrides the prefix classifier. This
      // matters for edge cases — e.g. an actuator command that sits under
      // a non-actuator namespace prefix.
      final registry = ref.read(commandRegistryProvider);
      final cmd = registry[action];

      // Rate gate runs next — keep a burst from a rogue shell / tunnel
      // client from hitting the daemon at all. The bucket is a single-
      // source-of-truth: cloud transport (Phase 6) and any future BLE path
      // share it so policy stays centralised.
      final limiter = ref.read(rateLimiterProvider);
      if (!limiter.tryAdmit(action, override: cmd?.rateClass)) {
        final cls = cmd?.rateClass ?? RateLimiter.classify(action);
        return {
          'error': 'rate limited',
          'code': 'RATE_LIMITED',
          'class': cls.name,
        };
      }
      if (cmd != null) {
        if (cmd.requiresStationary) {
          // Get GROUND TRUTH for speed, not the last pushed value — a stale
          // cached "moving" reading must never block a parked car. Null
          // (signal unavailable / live read failed) = allow; only a
          // trustworthy reading above the threshold blocks, with a dedicated
          // code so the LLM/overlay surfaces the right explanation.
          final speed = await resolveStationaryGateSpeed(
            ref.read(carClientProvider),
          );
          if (speed != null && speed > _stationarySpeedLimit) {
            return const {
              'error': 'not safe while moving',
              'code': 'UNSAFE_WHILE_MOVING',
            };
          }
        }
        // Registry-known command: dispatch through the bridge using
        // `cmd.resolve(args)` when the command needs an id transform
        // (parameterized like `comfort.massage` → `massage.<seat>.<field>`),
        // else `cmd.id` directly. The daemon-side action table
        // (encrypted from `.secrets/car_table/`) owns the actual
        // feature-id binding; there's no Dart-side controller
        // indirection.
        final resolved = cmd.resolve?.call(payload);
        final String actionId = resolved?.actionId ?? cmd.id;
        final Map<String, dynamic> resolvedArgs = resolved?.args ?? payload;
        return await ref
            .read(carBridgeProvider)
            .runAction(actionId, resolvedArgs);
      }
      final bridge = ref.read(carBridgeProvider);
      // Every branch uses `return await ...` so exceptions from the bridge
      // propagate into the try/catch below. A bare `return bridge.xxx()`
      // returns the Future without awaiting, and any thrown PlatformException
      // escapes the catch block to the caller — silent data leak.
      switch (action) {
        case 'get_status':
        case 'car_all_status':
          // Wire-compat snake_case status map sourced from the SDK's
          // hot cache. Same shape the legacy `bridge.readStatus()`
          // produced — label keys from `bydStatusLabelToCatalog`.
          final client = ref.read(carClientProvider);
          final out = <String, dynamic>{};
          bydStatusLabelToCatalog.forEach((label, name) {
            final v = client.value(name);
            if (v != null) out[label] = v;
          });
          return out;
        case 'run_action':
          return await bridge.runAction(
            payload['id'] as String,
            (payload['args'] as Map?)?.cast<String, dynamic>() ?? const {},
          );
        case 'run_unit':
          return await bridge.runUnit(
            payload['unit'] as String,
            (payload['args'] as List?)?.cast<String>() ?? const [],
          );
        case 'ac_transact':
          return await bridge.acTransact(
            payload['service'] as String,
            payload['method'] as String,
            args: (payload['args'] as Map?)?.cast<String, dynamic>(),
          );
        default:
          // Wire-id passthrough. If the action isn't a registry id but
          // IS a raw fast-action / unit-action id baked into the
          // encrypted car table (e.g. dev test bench dispatching
          // ``ac.power`` directly), let UnitDispatcher run it. Same
          // safety stack already executed above (integrity, rate, plus
          // stationary if a registry entry resolved). The daemon
          // returns ``unknown action: …`` if the id is not in any
          // table — re-shape that to the ``tool_not_found`` envelope
          // voice + tunnel callers expect, so an LLM emitting a name
          // not in the manifest still sees the structured error and
          // ``voice_tool_not_found_total`` keeps incrementing.
          final raw = await bridge.runAction(action, payload);
          final err = raw['error'];
          if (err is String && err.startsWith('unknown action')) {
            return {
              'error': 'tool_not_found',
              'code': 'TOOL_NOT_FOUND',
              'name': action,
            };
          }
          return raw;
      }
    } on PlatformException catch (e, st) {
      // Keep the code (short enum like 'CAR_BRIDGE_ERROR') since it's useful
      // for the LLM / tunnel client to branch on, but never echo the raw
      // Java message or details — they carry stack frames, file paths, and
      // exception class names that should not reach user-visible output.
      if (kDebugMode) {
        debugPrint(
          'router platform error on $action: '
          '${e.code} / ${e.message} / ${e.details}\n$st',
        );
      }
      return {'error': 'command failed', 'code': e.code};
    } catch (e, st) {
      if (kDebugMode) debugPrint('router error on $action: $e\n$st');
      return const {'error': 'command failed'};
    }
  }

  /// Reduce a dispatch result to a short opaque enum for the log line.
  /// Intentionally does not expose the error message — the hashed cmd + args
  /// plus this code is enough for frequency analysis without leaking
  /// anything about why a specific call failed.
  static String _outcomeCode(Map<String, dynamic> result) {
    if (!result.containsKey('error')) return 'ok';
    final code = result['code'];
    if (code is String && code.isNotEmpty) return code;
    return 'error';
  }
}

final carCommandRouterProvider = Provider<CarCommandRouter>((ref) {
  return CarCommandRouter(ref);
});
