/// Thin Dart wrapper around the `ilink/display` MethodChannel +
/// `ilink/display/events` EventChannel.
///
/// THIS IS THE ONLY FILE in the `display/` Dart layer that imports
/// `package:flutter/services.dart`. [DisplayFamily] and any test
/// against it depend on the [DisplayNativeBridge] interface, never
/// on `MethodChannel` directly. Project memory
/// `feedback_engineering_axes`: keep platform imports isolated.
library;

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';
import 'display_snapshot.dart';

/// Interface seam. Tests provide a fake [DisplayNativeBridge];
/// production wires [PlatformDisplayNativeBridge].
abstract class DisplayNativeBridge {
  Future<List<DisplaySnapshot>> list();

  /// Subscribe to display events. Yields a stream of
  /// [DisplayEvent] (added / removed / changed) with the current
  /// snapshot of the affected display when present.
  ///
  /// First emit is the full snapshot list — subscribers see it
  /// without racing the first hot-plug.
  Stream<DisplayEvent> events();

  /// Set logical density (DPI) for [displayId]. The host applies
  /// the active VehicleProfile's zoom remap, so passing display 3
  /// on Leopard 8 lands the override on display 5 (the cluster's
  /// addressable surface). Returns a [DensityResult] with the
  /// applied display id.
  Future<DensityResult> setDensity({required int displayId, required int dpi});

  /// Restore stock density on [displayId]. Same remap behaviour as
  /// [setDensity].
  Future<DensityResult> resetDensity({required int displayId});

  /// Active vehicle's capability bitmask + readable list. Computed by
  /// the host's `CapabilityRegistry` (backend overlay → static seed).
  /// Cheap (one map lookup + bit-decode).
  ///
  /// NOTE: this channel is the **legacy** path that still feeds the
  /// `display.list` snapshot (mini-app SDK consumes
  /// `r.vehicle.capabilityBits` from there). Host-side Dart code
  /// should consult `carProfileProvider` instead — it carries the
  /// full ProfileKey + action-support map in one hop, and survives
  /// the eventual removal of this channel.
  Future<VehicleCapabilityResult> capabilityBits({String? fingerprint});
}

/// Wire shape for `display.capabilityBits`. `bits` is the packed
/// bitmask; `capabilities` is the readable list (taxonomy order).
/// Both are present so SDK consumers can pick either path.
class VehicleCapabilityResult {
  const VehicleCapabilityResult({
    required this.bits,
    required this.capabilities,
    this.variantId,
  });

  final int bits;
  final List<String> capabilities;
  final String? variantId;

  factory VehicleCapabilityResult.fromMap(Map<String, Object?> m) =>
      VehicleCapabilityResult(
        // Method-channel marshals Long → int on Dart side.
        bits: (m['bits'] as num?)?.toInt() ?? 0,
        capabilities: ((m['capabilities'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        variantId: m['variantId'] as String?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'bits': bits,
    'capabilities': capabilities,
    if (variantId != null) 'variantId': variantId,
  };
}

/// Wire shape for `display.setDensity` / `display.resetDensity`.
/// `displayId` is the *applied* display (post profile remap) so
/// callers see where the change actually took effect.
class DensityResult {
  const DensityResult({required this.ok, required this.displayId, this.error});

  final bool ok;
  final int displayId;
  final String? error;

  factory DensityResult.fromMap(Map<String, Object?> m) => DensityResult(
    ok: m['ok'] as bool? ?? false,
    displayId: (m['displayId'] as num?)?.toInt() ?? -1,
    error: m['error'] as String?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'displayId': displayId,
    if (error != null) 'error': error,
  };
}

/// Production impl — talks to `DisplayPlatformPlugin.kt`.
class PlatformDisplayNativeBridge implements DisplayNativeBridge {
  PlatformDisplayNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel('ilink/display'),
       _event = eventChannel ?? const EventChannel('ilink/display/events');

  final MethodChannel _method;
  final EventChannel _event;

  @override
  Future<List<DisplaySnapshot>> list() async {
    Observability.breadcrumb(category: 'display.native', message: 'list');
    final raw = await _method.invokeListMethod<Object?>('list') ?? const [];
    return raw
        .map((e) => DisplaySnapshot.fromMap((e as Map).cast<String, Object?>()))
        .toList(growable: false);
  }

  @override
  Stream<DisplayEvent> events() {
    return _event.receiveBroadcastStream().map((raw) {
      final map = (raw as Map).cast<String, Object?>();
      return DisplayEvent.fromMap(map);
    });
  }

  @override
  Future<DensityResult> setDensity({
    required int displayId,
    required int dpi,
  }) async {
    Observability.breadcrumb(
      category: 'display.native',
      message: 'setDensity',
      data: {'displayId': displayId, 'dpi': dpi},
    );
    final raw = await _method.invokeMapMethod<String, Object?>(
      'setDensity',
      <String, Object?>{'displayId': displayId, 'dpi': dpi},
    );
    return DensityResult.fromMap(raw ?? const <String, Object?>{});
  }

  @override
  Future<DensityResult> resetDensity({required int displayId}) async {
    Observability.breadcrumb(
      category: 'display.native',
      message: 'resetDensity',
      data: {'displayId': displayId},
    );
    final raw = await _method.invokeMapMethod<String, Object?>(
      'resetDensity',
      <String, Object?>{'displayId': displayId},
    );
    return DensityResult.fromMap(raw ?? const <String, Object?>{});
  }

  @override
  Future<VehicleCapabilityResult> capabilityBits({String? fingerprint}) async {
    Observability.breadcrumb(
      category: 'display.native',
      message: 'capabilityBits',
      data: fingerprint == null ? null : {'fingerprint': fingerprint},
    );
    final raw = await _method.invokeMapMethod<String, Object?>(
      'capabilityBits',
      // Pass an empty map rather than null so the host's MethodCall
      // arguments are never the null reference (defensive — some
      // older flutter engines marshal null differently).
      <String, Object?>{
        // ignore: use_null_aware_elements -- key is a non-null literal
        if (fingerprint != null) 'fingerprint': fingerprint,
      },
    );
    return VehicleCapabilityResult.fromMap(raw ?? const <String, Object?>{});
  }
}
