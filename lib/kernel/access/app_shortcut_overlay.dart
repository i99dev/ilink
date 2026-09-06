import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thin wrapper around the `ilink/app_shortcuts` method channel that
/// drives the native [AppShortcutOverlayService] — the floating, per-app
/// launch buttons that hover over every app.
///
/// On iOS / web / test the platform side isn't registered; every method
/// degrades to `false` via [MissingPluginException] handling.
class AppShortcutOverlayChannel {
  AppShortcutOverlayChannel({MethodChannel? method})
    : _method = method ?? const MethodChannel(_kMethodChannel);

  static const _kMethodChannel = 'ilink/app_shortcuts';

  final MethodChannel _method;

  /// Show exactly these packages as floating buttons (one per package).
  /// An empty list tears the overlay down. Idempotent — safe to call on
  /// every settings change; the native side reconciles the live set.
  Future<bool> set(List<String> packages) async {
    try {
      final r = await _method.invokeMethod<bool>('set', {'packages': packages});
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop the floating-shortcuts overlay service (removes all buttons).
  Future<bool> clear() async {
    try {
      final r = await _method.invokeMethod<bool>('clear');
      return r ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// True if the native overlay service is currently alive in this process.
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

final appShortcutOverlayChannelProvider = Provider<AppShortcutOverlayChannel>(
  (_) => AppShortcutOverlayChannel(),
);
