/// Thin Dart wrapper around the `ilink/surface` MethodChannel.
///
/// THIS IS THE ONLY FILE in the `surface/` Dart layer that imports
/// `package:flutter/services.dart`.
library;

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';
import 'surface_snapshot.dart';

abstract class SurfaceNativeBridge {
  /// Open a surface on the given display. [appId] + [bundleUri] are
  /// resolved Dart-side from the install storage and forwarded to
  /// the native plugin so it knows which mini-app's HTML to mount
  /// in the secondary [WebView]. They aren't part of the SDK
  /// contract — the mini-app never sets them; the SurfaceFamily
  /// looks them up before each create call.
  Future<SurfaceCreateResult> create({
    required int displayId,
    required String appId,
    required String bundleUri,
    String? route,
  });
  Future<void> navigate({required String surfaceId, String? route});
  Future<void> destroy({required String surfaceId});
  Future<List<SurfaceSnapshot>> list();
}

class PlatformSurfaceNativeBridge implements SurfaceNativeBridge {
  PlatformSurfaceNativeBridge({MethodChannel? methodChannel})
    : _ch = methodChannel ?? const MethodChannel('ilink/surface');

  final MethodChannel _ch;

  @override
  Future<SurfaceCreateResult> create({
    required int displayId,
    required String appId,
    required String bundleUri,
    String? route,
  }) async {
    Observability.breadcrumb(
      category: 'surface.native',
      message: 'create',
      data: {'displayId': displayId, 'hasRoute': route != null},
    );
    final raw = await _ch.invokeMapMethod<String, Object?>('create', {
      'displayId': displayId,
      'appId': appId,
      'bundleUri': bundleUri,
      // ignore: use_null_aware_elements -- key is a non-null literal
      if (route != null) 'route': route,
    });
    return SurfaceCreateResult.fromMap(raw ?? const {});
  }

  @override
  Future<void> navigate({required String surfaceId, String? route}) async {
    Observability.breadcrumb(category: 'surface.native', message: 'navigate');
    await _ch.invokeMapMethod<String, Object?>('navigate', {
      'surfaceId': surfaceId,
      // ignore: use_null_aware_elements -- key is a non-null literal
      if (route != null) 'route': route,
    });
  }

  @override
  Future<void> destroy({required String surfaceId}) async {
    Observability.breadcrumb(category: 'surface.native', message: 'destroy');
    await _ch.invokeMapMethod<String, Object?>('destroy', {
      'surfaceId': surfaceId,
    });
  }

  @override
  Future<List<SurfaceSnapshot>> list() async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('list') ??
        const <String, Object?>{};
    final surfaces = (raw['surfaces'] as List?) ?? const [];
    return surfaces
        .map((e) => SurfaceSnapshot.fromMap((e as Map).cast<String, Object?>()))
        .toList(growable: false);
  }
}
