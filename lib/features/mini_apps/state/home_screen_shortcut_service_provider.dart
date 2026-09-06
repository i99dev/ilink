import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/home_screen_shortcut_service_android.dart';
import '../data/home_screen_shortcut_service_ios.dart';
import '../data/home_screen_shortcut_service_stub.dart';
import '../data/mini_app_icon_resolver_cached.dart';
import '../domain/home_screen_shortcut_service.dart';
import '../domain/mini_app_icon_resolver.dart';

/// Platform-gated [HomeScreenShortcutService] provider.
///
/// Single swap point for both runtime wiring and tests — unit tests
/// override this with a fake implementation; main just reads the right
/// platform impl. Checking `kIsWeb` first because `Platform.is…` throws
/// on web and we still want to analyze cleanly even if the app ever
/// lights up as a web build.
final homeScreenShortcutServiceProvider = Provider<HomeScreenShortcutService>((
  ref,
) {
  if (kIsWeb) return const StubHomeScreenShortcutService();
  if (Platform.isAndroid) return const AndroidHomeScreenShortcutService();
  if (Platform.isIOS) return const IosHomeScreenShortcutService();
  return const StubHomeScreenShortcutService();
});

/// Same shape for the icon resolver. The cached impl pulls from
/// `DefaultCacheManager`, which is shared with `cached_network_image`,
/// so the pin path reuses tile-render bytes with zero extra config.
final miniAppIconResolverProvider = Provider<MiniAppIconResolver>(
  (_) => CachedMiniAppIconResolver(),
);

/// Status is cheap to call and rarely changes (the launcher isn't
/// hot-swapped at runtime), so a [FutureProvider] is plenty — no
/// need for a notifier. Widgets watch through
/// [canPinMiniAppProvider] in mini_app_shortcut_status_provider.dart
/// rather than this directly, so the business rule lives in one place.
final homeScreenShortcutStatusProvider =
    FutureProvider<HomeScreenShortcutStatus>(
      (ref) => ref.watch(homeScreenShortcutServiceProvider).status(),
    );
