/// Port: fetch (or locate) a local file-system path to the bitmap for
/// a mini-app icon so the platform-channel side can decode it without
/// doing any networking itself.
///
/// The default impl wraps `flutter_cache_manager`'s `DefaultCacheManager`
/// — which `cached_network_image` already uses for tile rendering — so
/// the common path is zero-network: the user has already seen the tile,
/// the bytes are on disk, and `resolve` returns the cached path in
/// microseconds.
///
/// A throw here is non-fatal: the controller catches it, swaps to the
/// bundled launcher icon, and pins anyway with a `PinPartial` outcome
/// so the user isn't blocked by a flaky CDN.
abstract class MiniAppIconResolver {
  Future<String> resolve(String icon);
}
