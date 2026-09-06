/// Whether the device + launcher can host pinned shortcuts.
///
///   * [supported]   — `ShortcutManagerCompat.isRequestPinShortcutSupported`
///                     returned true; we may call [HomeScreenShortcutService.pin].
///   * [unsupported] — API < 26, iOS, or the user's launcher refuses
///                     pin requests. UI hides the action.
///   * [unknown]     — the status probe itself failed (platform error).
///                     UI hides the action but logs for visibility.
enum HomeScreenShortcutStatus { supported, unsupported, unknown }

/// Typed errors surfaced by the shortcut service. The controller maps
/// these onto user-facing outcomes so widgets never do error-string
/// pattern-matching themselves.
sealed class HomeScreenShortcutError implements Exception {
  const HomeScreenShortcutError();
}

/// Device OS / API level does not support pin shortcuts. iOS always
/// hits this; Android < 8.0 also.
class UnsupportedPlatformError extends HomeScreenShortcutError {
  const UnsupportedPlatformError();
  @override
  String toString() => 'UnsupportedPlatformError';
}

/// The launcher returned `false` from `requestPinShortcut` — usually
/// because the user's active launcher does not implement the pin API
/// (some stock launchers, car head-unit launchers, OEM skins).
class LauncherRefusedPinError extends HomeScreenShortcutError {
  const LauncherRefusedPinError();
  @override
  String toString() => 'LauncherRefusedPinError';
}

/// The icon bytes could not be resolved. Separated from
/// [ChannelFailureError] so the controller can fall back to a generic
/// launcher icon and still pin, rather than failing the whole request.
class IconResolveFailedError extends HomeScreenShortcutError {
  const IconResolveFailedError(this.cause);
  final Object cause;
  @override
  String toString() => 'IconResolveFailedError($cause)';
}

/// Catch-all for any platform-channel failure we don't recognise. The
/// [code] and [message] come straight from [PlatformException] so the
/// logger can emit them for debugging without losing specificity.
class ChannelFailureError extends HomeScreenShortcutError {
  const ChannelFailureError(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() =>
      'ChannelFailureError($code${message == null ? '' : ', $message'})';
}

/// Port for OS-level home-screen shortcut integration. One impl per
/// platform (Android, iOS, stub for tests); the [HomeScreenShortcutService]
/// itself is platform-agnostic so controllers, providers, and widgets
/// can be written once.
///
/// The [pin] contract takes a pre-resolved local [iconFilePath] rather
/// than a URL on purpose: keeping networking out of this port means
/// the Kotlin side never touches HTTP, icon caching stays in Dart where
/// `cached_network_image`'s `DefaultCacheManager` already holds the
/// bytes, and swap-in impls (iOS, stub) don't need to invent a
/// networking story.
abstract class HomeScreenShortcutService {
  /// Cheap enough to poll — implementations may cache, but must return
  /// quickly from a cached value on subsequent calls.
  Future<HomeScreenShortcutStatus> status();

  /// Creates (or requests the launcher create) a pinned shortcut for the
  /// mini-app identified by [id]. Throws a [HomeScreenShortcutError]
  /// subtype on failure — the controller catches and maps to outcomes.
  ///
  /// [deepLinkUrl] must be the canonical HTTPS App Link; the custom
  /// scheme is accepted by the manifest but the app-link form survives
  /// re-installs cleanly, so we always pin the primary form.
  Future<void> pin({
    required String id,
    required String label,
    required String deepLinkUrl,
    required String iconFilePath,
  });
}
