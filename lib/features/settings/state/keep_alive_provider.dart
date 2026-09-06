import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Channel + method names for the native "car online" keep-alive control
/// (Kotlin `ConnectivityChannel`). Constants so a contract test can prove
/// both sides declare the same strings.
class ConnectivityChannelNames {
  ConnectivityChannelNames._();
  static const String methodChannel = 'ilink/connectivity';
  static const String isKeepAliveEnabled = 'isKeepAliveEnabled';
  static const String setKeepAliveEnabled = 'setKeepAliveEnabled';
}

/// Seam over the native `ConnectivityService` enable flag. The native side
/// is the single source of truth (a SharedPreferences gate its start path
/// reads), so this only reads/writes it — no duplicate copy in
/// `AppSettings`. Defaults to ON when the platform can't answer (matches
/// the service's own default).
abstract class KeepAliveBridge {
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);
}

class PlatformKeepAliveBridge implements KeepAliveBridge {
  const PlatformKeepAliveBridge({this.mock = false});

  final bool mock;

  static const _method = MethodChannel(ConnectivityChannelNames.methodChannel);

  @override
  Future<bool> isEnabled() async {
    if (mock) return true;
    try {
      return await _method.invokeMethod<bool>(
            ConnectivityChannelNames.isKeepAliveEnabled,
          ) ??
          true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (mock) return;
    try {
      await _method.invokeMethod<void>(
        ConnectivityChannelNames.setKeepAliveEnabled,
        {'enabled': enabled},
      );
    } on PlatformException {
      // Best-effort — a transient native failure shouldn't crash settings.
    } on MissingPluginException {
      // Non-Android / test environment with no channel registered.
    }
  }
}

/// The connectivity channel only exists on Android (Kotlin
/// `ConnectivityChannel`). Elsewhere fall back to the mock bridge so the
/// settings page renders without throwing `MissingPluginException`.
bool get _keepAliveNativeAvailable {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android;
}

final keepAliveBridgeProvider = Provider<KeepAliveBridge>((ref) {
  return PlatformKeepAliveBridge(mock: !_keepAliveNativeAvailable);
});

/// Settings-facing state for the "stay online in the background" toggle.
///
/// `build()` reads the current value from the native [KeepAliveBridge]
/// (the single source of truth — what `ConnectivityService` consults on
/// each start), so the switch always reflects reality. [set] flips it
/// optimistically (instant switch response) then persists natively, which
/// also starts/stops the foreground service immediately.
class KeepAliveController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.read(keepAliveBridgeProvider).isEnabled();

  Future<void> set(bool enabled) async {
    state = AsyncData(enabled);
    await ref.read(keepAliveBridgeProvider).setEnabled(enabled);
  }
}

final keepAliveProvider = AsyncNotifierProvider<KeepAliveController, bool>(
  KeepAliveController.new,
);
