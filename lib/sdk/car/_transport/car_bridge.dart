import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/car_device_id.dart';
import '../sdk_config.dart';
import 'car_transport.dart';

/// Dart facade for the ADB / feature-ID bypass surface on the head unit.
/// Everything here eventually runs through `UnitDispatcher` (Kotlin) which
/// shells out via ADB loopback to the `testing_case` unit DEX files, or
/// talks to the raw `byd_airconditioning` binder via Parcel transactions.
///
/// Non-bypass platform calls (media session control, package launching,
/// location streams) live with their respective features — keep this
/// class narrow to the bypass surface only.
///
/// **Timeouts**: every call is bounded. A hung daemon or ADB socket should
/// surface as a failure map rather than a frozen UI. Fast path (direct
/// daemon setInt) bounded by [_fastTimeout]; slow path (shell-spawn DEX)
/// by [_slowTimeout]. Callers don't pick — the method picks.
class CarBridge implements CarTransport {
  const CarBridge({this.mockCar = false});

  /// When true, every method short-circuits to a canned response.
  /// Sourced from [sdkConfigProvider] via [carBridgeProvider]; the
  /// app injects the real value at boot.
  final bool mockCar;

  bool get _mock => mockCar;

  static const _channel = MethodChannel('ilink/car');

  /// Direct daemon setInt roundtrips in ~5-10 ms on a healthy daemon;
  /// 3 s is an order-of-magnitude slack for the FAST dispatch path.
  static const _fastTimeout = Duration(seconds: 3);

  /// `adb shell app_process64 …` can take 1-2 s per tap plus
  /// `byd_airconditioning` binder roundtrips. 8 s accommodates the worst
  /// case without letting the UI hang forever.
  static const _slowTimeout = Duration(seconds: 8);

  /// [carIdentityLocalOnly] reads VIN/device_id via Kotlin reflection on
  /// `android.os.SystemProperties.get`. On the FIRST call after a cold
  /// boot the platform-channel hop + reflection can exceed the 3 s
  /// [_fastTimeout] on slower BYD ROMs (notably DiLink 5.0 trims) — the
  /// channel times out, the map comes back without `device_id`, and the
  /// car pairs with an empty id (defeating server-side dedup). This read
  /// runs only at pairing/diagnostics, not on a hot path, so it gets a
  /// roomier bound to win the cold-start race.
  static const _identityTimeout = Duration(seconds: 6);

  /// Invoke a registered action id on the UnitDispatcher.
  @override
  Future<Map<String, dynamic>> runAction(
    String id, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_mock) {
      return {'ok': true, 'code': 0, 'mock': true, 'id': id};
    }
    return _guard(
      () async {
        final raw =
            await _channel.invokeMethod<Map<Object?, Object?>>('runAction', {
              'id': id,
              'args': args,
            }) ??
            const {};
        return raw.cast<String, dynamic>();
      },
      // runAction can route to FAST or UNIT on the Kotlin side; we can't
      // tell from here, so we pick the looser bound.
      timeout: _slowTimeout,
      label: 'runAction($id)',
    );
  }

  /// Direct unit invocation — bypasses the alias map. Handy for debug.
  @override
  Future<Map<String, dynamic>> runUnit(String unit, List<String> args) async {
    if (_mock) {
      return {'ok': true, 'code': 0, 'mock': true, 'unit': unit};
    }
    return _guard(
      () async {
        final raw =
            await _channel.invokeMethod<Map<Object?, Object?>>('runUnit', {
              'unit': unit,
              'args': args,
            }) ??
            const {};
        return raw.cast<String, dynamic>();
      },
      timeout: _slowTimeout,
      label: 'runUnit($unit)',
    );
  }

  @override
  Future<List<String>> knownActions() async {
    if (_mock) return const [];
    try {
      return await _channel
              .invokeListMethod<String>('knownActions')
              .timeout(_fastTimeout) ??
          const [];
    } on TimeoutException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<List<String>> knownUnits() async {
    if (_mock) return const [];
    try {
      return await _channel
              .invokeListMethod<String>('knownUnits')
              .timeout(_fastTimeout) ??
          const [];
    } on TimeoutException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<Map<String, int>> allFeaturesAuto() async {
    if (_mock) return const {};
    try {
      // Larger timeout — the host may be returning a 9k+ entry map.
      // Even at ~150 KB serialised, well under MethodChannel's
      // practical 1 MB ceiling, but the JSON parse is non-trivial.
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('allFeaturesAuto')
          .timeout(const Duration(seconds: 5));
      if (raw == null) return const {};
      final out = <String, int>{};
      raw.forEach((k, v) {
        if (k is String && v is int) out[k] = v;
      });
      return out;
    } on TimeoutException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<Map<String, int>> allKnownFeatures() async {
    if (_mock) return const {};
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('allKnownFeatures')
          .timeout(const Duration(seconds: 8));
      if (raw == null) return const {};
      final out = <String, int>{};
      raw.forEach((k, v) {
        if (k is String && v is int) out[k] = v;
      });
      return out;
    } on TimeoutException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<int?> getValueByName(String name) async {
    if (_mock) return null;
    try {
      final v = await _channel
          .invokeMethod<int>('getValueByName', {'name': name})
          .timeout(_fastTimeout);
      return v;
    } on TimeoutException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<String>> subscribePushByNames(List<String> names) async {
    if (_mock || names.isEmpty) return const [];
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('subscribePushByNames', {'names': names})
          .timeout(_fastTimeout);
      if (raw == null) return const [];
      return raw.whereType<String>().toList(growable: false);
    } on TimeoutException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<Map<String, int>> getValuesByName(List<String> names) async {
    if (_mock || names.isEmpty) return const {};
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getValuesByName', {
            'names': names,
          })
          .timeout(_fastTimeout);
      if (raw == null) return const {};
      final out = <String, int>{};
      raw.forEach((k, v) {
        if (k is String && v is int) out[k] = v;
      });
      return out;
    } on TimeoutException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<Map<String, String>> labelToCatalog() async {
    if (_mock) return const {};
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('labelToCatalog')
          .timeout(_fastTimeout);
      if (raw == null) return const {};
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
      return out;
    } on TimeoutException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<Map<String, dynamic>> registryStats() async {
    if (_mock) return const {};
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('registryStats')
          .timeout(_fastTimeout);
      if (raw == null) return const {};
      return Map<String, dynamic>.fromEntries(
        raw.entries
            .where((e) => e.key is String)
            .map((e) => MapEntry(e.key as String, e.value)),
      );
    } on TimeoutException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<Map<String, dynamic>> daemonStatus() async {
    if (_mock) return {'adb': true, 'daemon': true, 'mock': true};
    return _guard(
      () async {
        final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
          'daemonStatus',
        );
        return (raw ?? const {}).cast<String, dynamic>();
      },
      timeout: _fastTimeout,
      label: 'daemonStatus',
    );
  }

  /// Returns the head-unit identity probe used by the compat reporter:
  /// `android_build_manu`, `android_build_model`, `android_sdk_int`,
  /// `dilink_version_hint`, `byd_auto_mgr_present`,
  /// `byd_airconditioning_present`. Keys may be missing on devices where
  /// the reflection probe failed — consumers treat the map as best-effort.
  @override
  Future<Map<String, dynamic>> carIdentity() async {
    if (_mock) {
      return const {
        'android_build_manu': 'BYD',
        'android_build_model': 'LEOPARD8',
        'android_sdk_int': 33,
        'dilink_version_hint': 'DiLink5.1',
        'byd_auto_mgr_present': true,
        'byd_airconditioning_present': true,
        'mock': true,
      };
    }
    return _guard(
      () async {
        final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
          'carIdentity',
        );
        return (raw ?? const {}).cast<String, dynamic>();
      },
      timeout: _fastTimeout,
      label: 'carIdentity',
    );
  }

  /// Privacy-sensitive identity surface — VIN, car-mode-id, region —
  /// pulled from Android system properties on the head unit. Returns
  /// an empty map on devices that don't expose them (emulator, mock
  /// mode, restricted SELinux). NEVER ship these values unhashed off
  /// the device — see `lib/features/compat/data/device_id_hasher.dart` for
  /// the privacy-preserving alternative used by the compat reporter.
  ///
  /// Used by [deviceFingerprintProvider] to auto-fill the pairing
  /// payload (VIN + vehicle) so the user doesn't need to type it,
  /// AND by the dev test bench to confirm head-unit reachability.
  @override
  Future<Map<String, dynamic>> carIdentityLocalOnly() async {
    if (_mock) {
      return const {
        // Prefixed canonical device id per RENAME_BYD_DEVICE_ID_CONTRACT.md:
        // `<brand>:<native_id>`. Sourced from CarDeviceId.mockDeviceId so
        // the bridge, the settings seed, pairing and MQTT creds all use
        // the SAME mock id (a divergence desyncs the MQTT creds username
        // from settings.deviceId and the client refuses to connect).
        'device_id': CarDeviceId.mockDeviceId,
        'device_id_source': 'mock',
        'car_mode_id': '155',
        'model_variant': 'flagship',
        'vehicle_type': 'suv',
        'head_unit': 'DiLink5.1',
        'region': 'me',
        'model_name': 'Leopard 8',
      };
    }
    return _guard(
      () async {
        final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
          'carIdentityLocalOnly',
        );
        return (raw ?? const {}).cast<String, dynamic>();
      },
      timeout: _identityTimeout,
      label: 'carIdentityLocalOnly',
    );
  }

  /// Phase-9: one-shot ContentProvider snapshot for a family. The Kotlin
  /// side (`CarStatusProviderSource.readFamily`) consults the encrypted
  /// table for authority/path, queries with the asset's projection, and
  /// maps row columns onto the SDK's wire-shape field names. Returns
  /// `null` when the family isn't backed by a provider (live-state
  /// families flow through `readStatus` instead) or when the underlying
  /// query failed (permission denied, empty cursor, …).
  @override
  Future<Map<String, dynamic>?> readContentProvider(String family) async {
    if (_mock) return null;
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('readContentProvider', {
            'family': family,
          })
          .timeout(_fastTimeout);
      return raw?.cast<String, dynamic>();
    } on TimeoutException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Phase-9: subscribe to a family's ContentObserver. Returns the
  /// `observerId` to pass back to [unobserveContentProvider]. The host
  /// pushes snapshots through the `ilink/car/observers`
  /// EventChannel in `{family, observerId, snapshot}` envelopes; use
  /// [observerEventStream] to get the demultiplexed per-key stream.
  /// Returns `null` if the family isn't observable (no URI in catalog,
  /// permission denied at register time).
  Future<String?> observeContentProvider(String family) async {
    if (_mock) return null;
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('observeContentProvider', {
            'family': family,
          })
          .timeout(_fastTimeout);
      return raw?['observerId'] as String?;
    } on TimeoutException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Phase-9: drop the registration created by [observeContentProvider].
  /// Idempotent — passing an unknown id is a no-op on the Kotlin side.
  Future<void> unobserveContentProvider(
    String family,
    String observerId,
  ) async {
    if (_mock) return;
    try {
      await _channel
          .invokeMethod<void>('unobserveContentProvider', {
            'family': family,
            'observerId': observerId,
          })
          .timeout(_fastTimeout);
    } on TimeoutException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// `byd_airconditioning` raw Parcel path (fragrance, AC settings, air
  /// quality). Skips the ADB shell — that binder doesn't enforce the UID
  /// wall — so it's still "bypass" in spirit even though no shell is used.
  @override
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  }) async {
    if (_mock) return {'ok': true, 'code': 0, 'mock': true};
    return _guard(
      () async {
        final raw =
            await _channel.invokeMethod<Map<Object?, Object?>>('acTransact', {
              'service': service,
              'method': method,
              'args': args ?? const {},
            }) ??
            const {};
        return raw.cast<String, dynamic>();
      },
      timeout: _fastTimeout,
      label: 'acTransact($service.$method)',
    );
  }

  /// Wraps a channel call with a timeout. On timeout, returns the same
  /// error-map shape [CarCommandRouter] already forwards. PlatformException
  /// intentionally propagates — CarCommandRouter sanitizes it further up;
  /// catching it here would hide the code the router echoes back.
  Future<Map<String, dynamic>> _guard(
    Future<Map<String, dynamic>> Function() body, {
    required Duration timeout,
    required String label,
  }) async {
    try {
      return await body().timeout(timeout);
    } on TimeoutException {
      return {'error': 'timeout', 'code': 'CAR_BRIDGE_TIMEOUT', 'label': label};
    }
  }
}

final carBridgeProvider = Provider<CarBridge>(
  (ref) => CarBridge(mockCar: ref.watch(sdkConfigProvider).mockCar),
);
