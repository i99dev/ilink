import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The single, canonical derivation of a [Station](../domain/station.dart)
/// id from its stream URL.
///
/// M3U playlists carry no stable identifier — radio-browser UUIDs went away
/// with the backend. Favourites are persisted *by this id*, so the function
/// MUST stay deterministic and byte-stable across every future app version:
/// a second copy of this logic, or any tweak to the algorithm, silently
/// orphans every saved favourite. It therefore lives alone here and is
/// pinned by a golden test (`test/features/radio/station_identity_test.dart`).
///
/// The stream URL is the natural key — two playlist entries pointing at the
/// same stream are the same station regardless of display-name drift
/// between playlist files. Only surrounding whitespace is trimmed; nothing
/// else is normalised, because even a query-string or trailing-slash
/// difference can select a different bitrate/mount on the same host.
abstract final class StationIdentity {
  /// SHA-1 hex of the UTF-8 stream URL: 40 chars, collision-safe for a
  /// catalogue this size and cheap on the head unit's SoC. Returns an
  /// empty string for an empty/blank URL so the parser can reject it
  /// rather than mint a junk id.
  static String forStreamUrl(String streamUrl) {
    final normalised = streamUrl.trim();
    if (normalised.isEmpty) return '';
    return sha1.convert(utf8.encode(normalised)).toString();
  }
}
