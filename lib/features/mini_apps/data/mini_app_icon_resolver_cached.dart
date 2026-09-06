import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../domain/home_screen_shortcut_service.dart';
import '../domain/mini_app_icon_resolver.dart';

/// Resolver that reuses the same [DefaultCacheManager] instance
/// `cached_network_image` uses for tile rendering. On the pin happy
/// path the user *just* saw the tile, so the bitmap is already on
/// disk — `getSingleFile` returns instantly without touching the
/// network. First-pin-after-cache-purge does I/O once.
///
/// Throws [IconResolveFailedError] on any failure so the controller
/// can swap to the bundled launcher icon and still pin — never let
/// a flaky CDN break the whole Add-to-Home-Screen flow.
class CachedMiniAppIconResolver implements MiniAppIconResolver {
  CachedMiniAppIconResolver([BaseCacheManager? manager])
    : _manager = manager ?? DefaultCacheManager();

  final BaseCacheManager _manager;

  @override
  Future<String> resolve(String icon) async {
    try {
      final cached = await _manager.getFileFromCache(icon);
      if (cached == null) throw StateError('Icon is not available locally');
      return cached.file.path;
    } catch (e) {
      throw IconResolveFailedError(e);
    }
  }
}
