import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thin wrapper around the `ilink/bubble_overlay` method channel.
///
/// Coordinates passed to [show] / [showAndMinimize] are in raw screen
/// pixels (Flutter logical pixels multiplied by
/// `MediaQuery.devicePixelRatio`). The native side anchors the bubble
/// to the top-left corner with those coordinates as its initial offset.
///
/// On iOS / web / test environments the platform side is not
/// registered; every method degrades to `false` via
/// [MissingPluginException] handling so callers don't need to gate the
/// feature themselves.
class BubbleOverlayChannel {
  BubbleOverlayChannel({MethodChannel? method})
    : _method = method ?? const MethodChannel(_kMethodChannel);

  static const _kMethodChannel = 'ilink/bubble_overlay';

  final MethodChannel _method;

  /// Display the floating bubble at the given screen-pixel position.
  Future<bool> show({required int x, required int y}) async {
    try {
      final r = await _method.invokeMethod<bool>('show', {'x': x, 'y': y});
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop the floating bubble service.
  Future<bool> hide() async {
    try {
      final r = await _method.invokeMethod<bool>('hide');
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Send the hosting Activity to the back (Android
  /// `moveTaskToBack(true)`) so the BYD launcher reappears.
  Future<bool> minimize() async {
    try {
      final r = await _method.invokeMethod<bool>('minimize');
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Convenience: start the bubble and minimize the app in a single
  /// call. Both ops are best-effort; returns true only if BOTH the
  /// show and minimize legs succeeded.
  Future<bool> showAndMinimize({required int x, required int y}) async {
    final shown = await show(x: x, y: y);
    if (!shown) return false;
    return await minimize();
  }

  /// Persist whether the floating bubble may show when the app is
  /// backgrounded (Settings → Appearance toggle). Turning it off also
  /// hides a currently-shown bubble. Default on the native side is `true`.
  Future<bool> setEnabled(bool enabled) async {
    try {
      final r = await _method.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
      });
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// True if the native overlay service is currently alive in this
  /// process.
  Future<bool> isShowing() async {
    try {
      final r = await _method.invokeMethod<bool>('isShowing');
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final bubbleOverlayChannelProvider = Provider<BubbleOverlayChannel>((_) {
  return BubbleOverlayChannel();
});
