import '../../../kernel/playlists/m3u_entry.dart';
import '../../../kernel/playlists/media_identity.dart';

/// A live-TV channel — the TV feature's analogue of radio's `Station`.
///
/// Plain immutable value class (no codegen, matching the project toolchain).
/// Equality is identity-based via [id] to keep `==` O(1) for Riverpod change
/// detection. [id] is the SHA-1 of the stream URL (see [MediaIdentity]) so it
/// is stable across catalogue refreshes and consistent with user-imported
/// playlists that carry no `tvg-id`.
///
/// Three constructors feed the three sources:
///   * [Channel.fromCatalogJson] — the ilink iptv-rest-api shard wire shape.
///   * [Channel.fromM3uEntry] — a user-imported .m3u/.m3u8 playlist.
///   * [Channel.fromJson] — our own cache/favourites snapshot round-trip.
class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.tvgId,
    this.logo,
    this.group,
    this.country,
    this.categories = const [],
    this.quality,
    this.isHls = true,
    this.referrer,
    this.userAgent,
  });

  /// The iptv-rest-api shard shape:
  /// `{ id, name, url, logo, country, categories, quality, headers:{referrer,userAgent} }`
  factory Channel.fromCatalogJson(Map<String, dynamic> j) {
    final url = (j['url'] as String?)?.trim() ?? '';
    final headers = j['headers'] as Map<String, dynamic>?;
    return Channel(
      id: MediaIdentity.forStreamUrl(url),
      name: (j['name'] as String?)?.trim() ?? '',
      streamUrl: url,
      tvgId: j['id'] as String?,
      logo: j['logo'] as String?,
      country: j['country'] as String?,
      categories: (j['categories'] as List?)?.cast<String>() ?? const [],
      quality: j['quality'] as String?,
      isHls: url.contains('.m3u8'),
      referrer: headers?['referrer'] as String?,
      userAgent: headers?['userAgent'] as String?,
    );
  }

  /// Map a parsed [M3uEntry] (user import) onto a channel.
  factory Channel.fromM3uEntry(M3uEntry e) => Channel(
    id: MediaIdentity.forStreamUrl(e.url),
    name: e.name,
    streamUrl: e.url,
    tvgId: e.tvgId,
    logo: e.logo,
    group: e.group,
    categories: e.group != null ? [e.group!] : const [],
    isHls: e.isHls,
    referrer: e.referrer,
    userAgent: e.userAgent,
  );

  /// Cache/favourites snapshot round-trip (our own snake_case shape).
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    streamUrl: j['stream_url'] as String? ?? '',
    tvgId: j['tvg_id'] as String?,
    logo: j['logo'] as String?,
    group: j['group'] as String?,
    country: j['country'] as String?,
    categories: (j['categories'] as List?)?.cast<String>() ?? const [],
    quality: j['quality'] as String?,
    isHls: j['is_hls'] as bool? ?? true,
    referrer: j['referrer'] as String?,
    userAgent: j['user_agent'] as String?,
  );

  final String id;
  final String name;
  final String streamUrl;

  /// Upstream `tvg-id` (e.g. `BBCNews.uk`) when known. Not the identity.
  final String? tvgId;
  final String? logo;
  final String? group;
  final String? country;
  final List<String> categories;

  /// Best known rendition label, e.g. `1080p`. Display-only.
  final String? quality;
  final bool isHls;

  /// Per-stream HTTP headers some IPTV origins require. Sent on the
  /// `VideoPlayerController` request.
  final String? referrer;
  final String? userAgent;

  /// HTTP request headers for the player. Empty when the origin needs none.
  Map<String, String> get httpHeaders => {
    if (referrer != null && referrer!.isNotEmpty) 'Referer': referrer!,
    if (userAgent != null && userAgent!.isNotEmpty) 'User-Agent': userAgent!,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'stream_url': streamUrl,
    'tvg_id': tvgId,
    'logo': logo,
    'group': group,
    'country': country,
    'categories': categories,
    'quality': quality,
    'is_hls': isHls,
    'referrer': referrer,
    'user_agent': userAgent,
  };

  @override
  bool operator ==(Object other) => other is Channel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
