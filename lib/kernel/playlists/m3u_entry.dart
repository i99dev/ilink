/// A single parsed M3U entry — media-neutral.
///
/// [parseM3uEntries] produces these; each feature maps them onto its own
/// domain model (radio `Station`, TV `Channel`). Living in `kernel/` lets
/// radio and TV share one battle-tested parser instead of each carrying a
/// near-duplicate.
///
/// Unlike a radio-only parser this preserves the bits live-TV streams need:
/// `tvgId` (channel identity), and the per-stream HTTP [referrer] /
/// [userAgent] that many IPTV origins require (carried in the source as
/// `#EXTVLCOPT:http-referrer=` / `http-user-agent=`).
class M3uEntry {
  const M3uEntry({
    required this.url,
    required this.name,
    this.tvgId,
    this.logo,
    this.group,
    this.attributes = const {},
    this.referrer,
    this.userAgent,
  });

  /// Absolute http(s) stream URL. Relative paths are rejected by the parser.
  final String url;

  /// Display title from the `#EXTINF` line, or the URL host as a fallback.
  final String name;

  /// `tvg-id` attribute — the upstream channel id when present.
  final String? tvgId;

  /// `tvg-logo` attribute.
  final String? logo;

  /// `group-title` attribute (or a trailing `#EXTGRP` directive).
  final String? group;

  /// All raw `key="value"` attributes from the `#EXTINF` line, lowercased
  /// keys. Kept so feature mappers can read attributes the typed fields
  /// above don't cover without re-parsing.
  final Map<String, String> attributes;

  /// `#EXTVLCOPT:http-referrer=` — sent as the `Referer` request header.
  final String? referrer;

  /// `#EXTVLCOPT:http-user-agent=` — sent as the `User-Agent` request header.
  final String? userAgent;

  bool get isHls => url.contains('.m3u8');
}
