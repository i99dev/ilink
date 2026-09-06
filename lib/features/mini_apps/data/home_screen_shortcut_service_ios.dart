import '../domain/home_screen_shortcut_service.dart';

/// iOS impl — there is no first-party OS API for a third-party app to
/// pin a launcher icon. `SiriKit` / `App Intents` can surface the
/// mini-app in Spotlight and the Shortcuts app but not on the home
/// screen proper, and that's a separate design decision.
///
/// Returning `unsupported` here is deliberately not an error: the
/// controller treats it as a first-class state and the UI hides the
/// action so iOS users never see a disabled button.
class IosHomeScreenShortcutService implements HomeScreenShortcutService {
  const IosHomeScreenShortcutService();

  @override
  Future<HomeScreenShortcutStatus> status() async =>
      HomeScreenShortcutStatus.unsupported;

  @override
  Future<void> pin({
    required String id,
    required String label,
    required String deepLinkUrl,
    required String iconFilePath,
  }) async {
    throw const UnsupportedPlatformError();
  }
}
