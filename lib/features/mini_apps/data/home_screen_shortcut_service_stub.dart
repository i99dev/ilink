import '../domain/home_screen_shortcut_service.dart';

/// Test / fallback impl. Used when:
///
///   * A unit test needs a [HomeScreenShortcutService] with no
///     platform channel behind it.
///   * The app boots on a platform we don't support (e.g. Windows /
///     Linux desktop used during dev) — the service never throws, just
///     reports unsupported and refuses to pin.
class StubHomeScreenShortcutService implements HomeScreenShortcutService {
  const StubHomeScreenShortcutService();

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
