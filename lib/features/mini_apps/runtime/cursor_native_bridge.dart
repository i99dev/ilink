/// Thin Dart wrapper around the `ilink/cursor` MethodChannel.
///
/// THIS IS THE ONLY FILE in the `cursor/` Dart layer that imports
/// `package:flutter/services.dart`. [CursorFamily] and any test
/// against it depend on the [CursorNativeBridge] interface, never
/// on `MethodChannel` directly. Project memory
/// `feedback_engineering_axes`: keep platform imports isolated.
library;

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';

abstract class CursorNativeBridge {
  /// Attach a cursor view to the IVI's display. The `targetDisplayId`
  /// is metadata the SDK uses to translate IVI touch coordinates;
  /// the actual cursor view is always drawn on the IVI itself
  /// (drawing on the cluster is signature-gated — see project memory
  /// `project_leopard8_cluster_signature_gate`).
  ///
  /// Returns `true` on success, `false` if SYSTEM_ALERT_WINDOW
  /// hasn't been granted (caller should prompt the user to enable
  /// "Display over other apps").
  Future<bool> attach({required int targetDisplayId, required String style});

  Future<void> detach();

  /// Hot-path: 60 Hz during a drag. Implementations MUST avoid
  /// per-call allocation and route to a pre-existing view's
  /// translation transform. See [CursorOverlayManager.kt].
  Future<void> move({required double x, required double y});

  Future<void> style(String style);
}

class PlatformCursorNativeBridge implements CursorNativeBridge {
  PlatformCursorNativeBridge({MethodChannel? methodChannel})
    : _method = methodChannel ?? const MethodChannel('ilink/cursor');

  final MethodChannel _method;

  @override
  Future<bool> attach({
    required int targetDisplayId,
    required String style,
  }) async {
    Observability.breadcrumb(
      category: 'cursor.native',
      message: 'attach',
      data: {'targetDisplayId': targetDisplayId},
    );
    final ok = await _method.invokeMethod<bool>('attach', {
      'targetDisplayId': targetDisplayId,
      'style': style,
    });
    return ok ?? false;
  }

  @override
  Future<void> detach() async {
    Observability.breadcrumb(category: 'cursor.native', message: 'detach');
    await _method.invokeMethod<void>('detach');
  }

  @override
  Future<void> move({required double x, required double y}) async {
    await _method.invokeMethod<void>('move', {'x': x, 'y': y});
  }

  @override
  Future<void> style(String style) async {
    await _method.invokeMethod<void>('style', {'style': style});
  }
}
