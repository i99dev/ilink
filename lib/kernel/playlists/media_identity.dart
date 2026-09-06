import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Canonical derivation of a stable media item id from its stream URL.
///
/// Shared by every playlist-backed feature (radio, TV). Favourites are
/// persisted *by this id*, so the function MUST stay deterministic and
/// byte-stable across app versions — any tweak silently orphans saved
/// favourites. Pinned by a golden test.
///
/// The stream URL is the natural key: two playlist entries pointing at the
/// same stream are the same channel regardless of display-name drift across
/// playlist files / catalogue refreshes. Only surrounding whitespace is
/// trimmed; nothing else is normalised, because even a query-string or
/// trailing-slash difference can select a different rendition on the same
/// host.
abstract final class MediaIdentity {
  /// SHA-1 hex of the UTF-8 stream URL (40 chars): collision-safe for a
  /// catalogue this size and cheap on the head unit's SoC. Returns an empty
  /// string for an empty/blank URL so callers can reject it rather than
  /// mint a junk id.
  static String forStreamUrl(String streamUrl) {
    final normalised = streamUrl.trim();
    if (normalised.isEmpty) return '';
    return sha1.convert(utf8.encode(normalised)).toString();
  }
}
