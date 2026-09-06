import 'package:flutter/services.dart';

import '../domain/home_screen_shortcut_service.dart';

/// Android implementation. Delegates to a Kotlin method-channel handler
/// (`HomeScreenShortcutHandler.kt`) that wraps `ShortcutManagerCompat`.
///
/// The channel contract is narrow on purpose — two methods, no state.
/// Any error code the Kotlin side does not explicitly map comes back
/// as a generic `ChannelFailureError` so the controller never has to
/// match on raw platform-exception strings.
class AndroidHomeScreenShortcutService implements HomeScreenShortcutService {
  const AndroidHomeScreenShortcutService([MethodChannel? channel])
    : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'ilink/home_screen_shortcut',
  );

  final MethodChannel _channel;

  @override
  Future<HomeScreenShortcutStatus> status() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isPinSupported');
      return (ok ?? false)
          ? HomeScreenShortcutStatus.supported
          : HomeScreenShortcutStatus.unsupported;
    } on PlatformException {
      // Probe failures aren't fatal — we degrade to "unknown" so the UI
      // hides the action but a future retry can succeed.
      return HomeScreenShortcutStatus.unknown;
    }
  }

  @override
  Future<void> pin({
    required String id,
    required String label,
    required String deepLinkUrl,
    required String iconFilePath,
  }) async {
    try {
      await _channel.invokeMethod<void>('pinShortcut', {
        'id': id,
        'label': label,
        'deepLinkUrl': deepLinkUrl,
        'iconFilePath': iconFilePath,
      });
    } on PlatformException catch (e) {
      throw _mapError(e);
    }
  }

  /// Central mapping — keeps the exception surface reviewable in one
  /// place. Adding a new error means one entry here and one catch in
  /// the controller, no widget changes.
  static HomeScreenShortcutError _mapError(PlatformException e) {
    switch (e.code) {
      case 'UNSUPPORTED_SDK':
      case 'LAUNCHER_UNSUPPORTED':
        return const UnsupportedPlatformError();
      case 'LAUNCHER_REFUSED':
        return const LauncherRefusedPinError();
      default:
        return ChannelFailureError(e.code, e.message);
    }
  }
}
