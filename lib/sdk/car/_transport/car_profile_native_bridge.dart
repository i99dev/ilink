/// Thin Dart wrapper around the `ilink/car_profile` MethodChannel.
/// Replaces the older `display.capabilityBits` shortcut — the
/// CarProfile snapshot now carries everything both gates need
/// (bitmask, action support, fallback state, friendly name) in one
/// platform-channel hop.
///
/// THIS IS THE ONLY FILE in the `core/car/` Dart layer that imports
/// `package:flutter/services.dart`. The provider depends on this
/// interface, never on `MethodChannel` directly — tests fake the
/// bridge, never the platform.
library;

import 'package:flutter/services.dart';

import '../../_internal/logger.dart';
import '../identity/car_profile.dart';

const _log = Logger('CarProfileNative');

/// Interface seam for tests. Production wires
/// [PlatformCarProfileNativeBridge].
abstract class CarProfileNativeBridge {
  /// Fetch the active vehicle's full CarProfile. One platform-channel
  /// hop, cached by the provider for the process lifetime.
  Future<CarProfile> snapshot();

  /// Per-action support fast lookup. Used when a caller only needs
  /// support for one action and the snapshot's actionSupport map
  /// doesn't carry it (rare — most callers consult the cached
  /// snapshot).
  Future<CarActionSupport> actionSupport(String actionId);
}

class PlatformCarProfileNativeBridge implements CarProfileNativeBridge {
  PlatformCarProfileNativeBridge({MethodChannel? methodChannel})
    : _method = methodChannel ?? const MethodChannel('ilink/car_profile');

  final MethodChannel _method;

  @override
  Future<CarProfile> snapshot() async {
    _log.d('snapshot');
    final raw = await _method.invokeMapMethod<String, Object?>('snapshot');
    return CarProfile.fromMap(raw ?? const <String, Object?>{});
  }

  @override
  Future<CarActionSupport> actionSupport(String actionId) async {
    _log.d('actionSupport id=$actionId');
    final raw = await _method.invokeMapMethod<String, Object?>(
      'actionSupport',
      <String, Object?>{'actionId': actionId},
    );
    final ok = (raw?['ok'] as bool?) ?? false;
    if (!ok) return CarActionSupport.unknownAssumeSupported;
    return CarActionSupport.fromWire(raw?['support'] as String?);
  }
}
