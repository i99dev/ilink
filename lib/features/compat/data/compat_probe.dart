import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/_car_domain/command/command.dart';
import '../../../features/_car_domain/command/registry.dart';
import '../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../sdk/car/client.dart';

/// Per-call timeout. Tunable by telemetry — 3 s was too tight for DiLink
/// under load; 5 s covers a slow daemon without wedging the whole scan
/// for too long.
const int kProbeTimeoutSeconds = 5;

/// Outcome of probing one command. The probe never throws — every
/// failure mode lands in a dedicated variant so callers can render
/// sensible status text without catch blocks.
sealed class ProbeOutcome {
  const ProbeOutcome();

  Map<String, dynamic> toJson();
}

class ProbeReachable extends ProbeOutcome {
  const ProbeReachable({this.readbackValue});
  final int? readbackValue;
  @override
  Map<String, dynamic> toJson() => {
    'status': 'reachable',
    if (readbackValue != null) 'readback_value': readbackValue,
  };
}

class ProbeUnknownToDaemon extends ProbeOutcome {
  const ProbeUnknownToDaemon();
  @override
  Map<String, dynamic> toJson() => const {'status': 'unknown_to_daemon'};
}

class ProbeInactive extends ProbeOutcome {
  const ProbeInactive();
  @override
  Map<String, dynamic> toJson() => const {
    'status': 'inactive',
    'readback_value': 65535,
  };
}

class ProbeNotReady extends ProbeOutcome {
  const ProbeNotReady();
  @override
  Map<String, dynamic> toJson() => const {
    'status': 'not_ready',
    'readback_value': -10013,
  };
}

class ProbeTimeout extends ProbeOutcome {
  const ProbeTimeout();
  @override
  Map<String, dynamic> toJson() => const {'status': 'timeout'};
}

class ProbeBridgeError extends ProbeOutcome {
  const ProbeBridgeError(this.message);
  final String message;
  @override
  Map<String, dynamic> toJson() => {
    'status': 'bridge_error',
    'message': message,
  };
}

class ProbeDaemonOffline extends ProbeOutcome {
  const ProbeDaemonOffline();
  @override
  Map<String, dynamic> toJson() => const {'status': 'daemon_offline'};
}

/// One row in the probe result, keyed by registry id.
class ProbeResult {
  const ProbeResult({
    required this.registryId,
    required this.wireId,
    required this.knownToDaemon,
    this.readbackField,
    required this.outcome,
  });

  final String registryId;
  final String wireId;
  final bool knownToDaemon;
  final String? readbackField;
  final ProbeOutcome outcome;

  Map<String, dynamic> toJson() => {
    'registry_id': registryId,
    'wire_id': wireId,
    'known_to_daemon': knownToDaemon,
    if (readbackField != null) 'readback_field': readbackField,
    ...outcome.toJson(),
  };
}

/// Full read-only probe of the car command surface. Never fires
/// actuators — only calls [CarBridge.knownActions], [CarBridge.readStatus]
/// and [CarBridge.daemonStatus]. The resulting list is the source of
/// truth for the CompatScreen table and the `commands` array in the
/// uploaded report.
///
/// Pure Dart: takes [CarBridge] + [registry] by ctor so tests inject
/// fakes without Riverpod.
class CompatProbe {
  CompatProbe({
    required this.client,
    required this.registry,
    this.timeoutSeconds = kProbeTimeoutSeconds,
  });

  final CarClient client;
  final Map<String, CarCommand> registry;

  final int timeoutSeconds;

  /// Latest values from the last [run]. The compat screen reads these
  /// when building the uploaded report so it doesn't have to fire a
  /// second round of `knownActions` / `daemonStatus` bridge calls for
  /// data we already have.
  List<String> _lastKnownActions = const [];
  Map<String, dynamic> _lastDaemonStatus = const {};

  /// Snapshot of `knownActions` from the most recent [run]. Empty list
  /// before the first run completes.
  List<String> get lastKnownActions => _lastKnownActions;

  /// Snapshot of `daemonStatus` from the most recent [run]. Empty map
  /// before the first run completes.
  Map<String, dynamic> get lastDaemonStatus => _lastDaemonStatus;

  /// Map of registry id → wire id for the commands where the public
  /// registry namespace doesn't match the encrypted-table action id.
  /// Without this the compat probe reports valid commands as
  /// ``unknown_to_daemon`` — fleet reports then claim AC / windows /
  /// seats are unsupported on cars where they actually work.
  ///
  /// Excluded on purpose:
  ///   * `climate.comfort_mode`, `climate.rear_lock` — AIDL-binder only,
  ///     no fast-action row. ``unknown_to_daemon`` is the correct signal.
  ///   * `seat.vent.{pass,rl,rr}` — no Kotlin UNIT entry today; their
  ///     unknown status is accurate.
  ///   * `comfort.massage`, `comfort.atmos` — templated wire ids; the
  ///     probe can't pin to one fast-action without misreporting the
  ///     others.
  static const Map<String, String> _wireOverride = {
    // Trunk: registry namespaces under door, wire under trunk.
    'door.trunk.open': 'trunk.open',
    'door.trunk.close': 'trunk.close',

    // Climate: registry ``climate.*`` ↔ wire ``ac.*``.
    'climate.power': 'ac.power',
    'climate.temp': 'ac.temp',
    'climate.fan': 'ac.fan',
    'climate.mode': 'ac.mode',
    'climate.cycle': 'ac.cycle',
    'climate.defrost_f': 'ac.defrost_f',
    'climate.defrost_r': 'ac.defrost_r',
    'climate.compressor': 'ac.compressor',
    'climate.max_hot': 'ac.max_hot',
    'climate.max_cool': 'ac.max_cool',

    // Windows: registry decomposes one wire id into open/close/stop/down
    // sub-actions; all four registry rows probe the same wire key. The
    // ``window.fr.*`` registry rows map to the ``window.rf`` wire id —
    // the encrypted table preserves a historical fr/rf flip (see
    // ActionIds.windowFrontRight).
    'window.fl.open': 'window.fl',
    'window.fl.close': 'window.fl',
    'window.fl.stop': 'window.fl',
    'window.fl.down': 'window.fl',
    'window.fr.open': 'window.rf',
    'window.fr.close': 'window.rf',
    'window.fr.stop': 'window.rf',
    'window.fr.down': 'window.rf',
    'window.rl.open': 'window.rl',
    'window.rl.close': 'window.rl',
    'window.rl.stop': 'window.rl',
    'window.rl.down': 'window.rl',
    'window.rr.open': 'window.rr',
    'window.rr.close': 'window.rr',
    'window.rr.stop': 'window.rr',
    'window.rr.down': 'window.rr',

    // Seats: registry ``seat.heat.<seat>`` ↔ wire ``heat.<seat>.level``;
    // ditto vent for the driver only (rest absent in encrypted table).
    'seat.heat.drv': 'heat.drv.level',
    'seat.heat.pass': 'heat.pass.level',
    'seat.heat.rl': 'heat.rl.level',
    'seat.heat.rr': 'heat.rr.level',
    'seat.vent.drv': 'vent.drv.level',

    // Comfort: registry ``comfort.frag.*`` ↔ wire ``frag.*``.
    'comfort.frag.on': 'frag.on',
    'comfort.frag.off': 'frag.off',
  };

  /// Subset of registry ids that map to a readStatus field. Absent
  /// entries → readback unknown (but the command may still be reachable).
  /// Kept as a static const so it's easy to grep and extend as more
  /// fields arrive on the Kotlin side.
  static const Map<String, String> _readbackField = {
    'door.lock': 'door_lock',
    'climate.power': 'ac_power',
    'climate.temp': 'ac_target_temp',
    'climate.fan': 'ac_fan',
    'climate.mode': 'ac_wind_mode',
    'climate.cycle': 'ac_cycle',
    'light.head': 'headlight',
    'light.head.on': 'headlight',
    'light.head.off': 'headlight',
    'light.fog_f': 'front_fog',
    'light.fog_r': 'rear_fog',
  };

  String _wireIdFor(CarCommand cmd) => _wireOverride[cmd.id] ?? cmd.id;

  /// Produces one [ProbeResult] per [CarCommand] in the registry. If the
  /// daemon is offline, every result is [ProbeDaemonOffline] — we don't
  /// try to interrogate a dead daemon. If [readStatus] times out or
  /// throws, the readback side just stays blank; individual commands
  /// are still classified as `reachable`/`unknownToDaemon` from
  /// `knownActions` alone.
  Future<List<ProbeResult>> run() async {
    final daemon = await _safe<Map<String, dynamic>>(
      client.daemonStatus,
      fallback: const {},
    );
    _lastDaemonStatus = Map.unmodifiable(daemon);
    final daemonOnline = daemon['daemon'] == true || daemon['mock'] == true;

    if (!daemonOnline) {
      return [
        for (final cmd in registry.values)
          ProbeResult(
            registryId: cmd.id,
            wireId: _wireIdFor(cmd),
            knownToDaemon: false,
            readbackField: _readbackField[cmd.id],
            outcome: const ProbeDaemonOffline(),
          ),
      ];
    }

    final knownList = await _safe<List<String>>(
      client.knownActions,
      fallback: const [],
    );
    _lastKnownActions = List.unmodifiable(knownList);
    final known = Set<String>.from(knownList);
    final status = await _readStatus();

    return [for (final cmd in registry.values) _classify(cmd, known, status)];
  }

  /// Snake_case status snapshot sourced from the SDK's hot cache.
  /// Mirrors the legacy `bridge.readStatus()` shape — label keys come
  /// from `bydStatusLabelToCatalog`.
  Future<Map<String, dynamic>> _readStatus() async {
    final out = <String, dynamic>{};
    bydStatusLabelToCatalog.forEach((label, name) {
      final v = client.value(name);
      if (v != null) out[label] = v;
    });
    return out;
  }

  ProbeResult _classify(
    CarCommand cmd,
    Set<String> known,
    Map<String, dynamic> status,
  ) {
    final wireId = _wireIdFor(cmd);
    final field = _readbackField[cmd.id];
    final raw = field == null ? null : status[field];
    final readback = raw is int ? raw : null;

    if (!known.contains(wireId)) {
      return ProbeResult(
        registryId: cmd.id,
        wireId: wireId,
        knownToDaemon: false,
        readbackField: field,
        outcome: const ProbeUnknownToDaemon(),
      );
    }
    if (readback == 65535) {
      return ProbeResult(
        registryId: cmd.id,
        wireId: wireId,
        knownToDaemon: true,
        readbackField: field,
        outcome: const ProbeInactive(),
      );
    }
    if (readback == -10013) {
      return ProbeResult(
        registryId: cmd.id,
        wireId: wireId,
        knownToDaemon: true,
        readbackField: field,
        outcome: const ProbeNotReady(),
      );
    }
    return ProbeResult(
      registryId: cmd.id,
      wireId: wireId,
      knownToDaemon: true,
      readbackField: field,
      outcome: ProbeReachable(readbackValue: readback),
    );
  }

  /// Wrap a single bridge call with timeout + platform-exception
  /// catching. Returns [fallback] on any failure — we want the probe to
  /// finish even if one call hangs or throws, so partial data is better
  /// than none.
  Future<T> _safe<T>(Future<T> Function() fn, {required T fallback}) async {
    try {
      return await fn().timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      return fallback;
    } catch (_) {
      return fallback;
    }
  }
}

final compatProbeProvider = Provider<CompatProbe>((ref) {
  return CompatProbe(
    client: ref.read(carClientProvider),
    registry: ref.read(commandRegistryProvider),
  );
});
