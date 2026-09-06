/// Thin Dart wrapper around the `ilink/boot` MethodChannel.
///
/// THIS IS THE ONLY FILE in the `boot/` Dart layer that imports
/// `package:flutter/services.dart` — [BootLauncher] stays
/// platform-agnostic so unit tests can supply a fake bridge.
library;

import 'package:flutter/services.dart';

import '../../../platform/observability/observability.dart';

class BootState {
  const BootState({required this.bootEpochMs, required this.pendingAtMs});

  /// `System.currentTimeMillis() - SystemClock.elapsedRealtime()` —
  /// the wall-clock instant the device booted. Stable across the
  /// life of one boot; changes on every reboot.
  final int bootEpochMs;

  /// Non-zero when [BootCompletedReceiver] staged a replay for the
  /// current boot. Set on `BOOT_COMPLETED`, cleared by
  /// [BootLauncher] after a successful replay.
  final int pendingAtMs;
}

abstract class BootNativeBridge {
  Future<BootState> bootState();
  Future<void> clearPending();
}

class PlatformBootNativeBridge implements BootNativeBridge {
  PlatformBootNativeBridge({MethodChannel? methodChannel})
    : _ch = methodChannel ?? const MethodChannel('ilink/boot');

  final MethodChannel _ch;

  @override
  Future<BootState> bootState() async {
    Observability.breadcrumb(category: 'boot.native', message: 'bootState');
    final raw = await _ch.invokeMapMethod<String, Object?>('bootState');
    return BootState(
      bootEpochMs: (raw?['bootEpochMs'] as num?)?.toInt() ?? 0,
      pendingAtMs: (raw?['pendingAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> clearPending() async {
    Observability.breadcrumb(category: 'boot.native', message: 'clearPending');
    await _ch.invokeMethod<void>('clearPending');
  }
}
