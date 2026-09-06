import '../domain/station.dart';
import 'station_identity.dart';

/// Hard upper bound on stations materialised from a single playlist file.
///
/// This is the project's scalability lever: the `---everything-*-repo`
/// files run to 28–78 MB and grow unbounded, but everything downstream of
/// the parser (memory, JSON cache blob size, in-memory search filter) is
/// then O(≤cap) *forever*, independent of how large the upstream files
/// become. 5000 fully covers the largest browsable source we actually
/// fetch (`---everything-full.m3u`, ~2.7k named entries) with headroom
/// for upstream growth, while still hard-bounding a runaway file. A
/// ~2.7k-row list is lazily built by `ListView.builder` (prototypeItem)
/// so it stays smooth on the IVI.
const int kDefaultStationCap = 5000;

/// Pure, isolate-safe M3U → [Station] parser. No IO, no platform handles,
/// no `dart:io` — so [parseM3u] can be handed straight to `compute()` for
/// large bodies without any extra plumbing (see `GithubPlaylistApi`).
///
/// Tolerates the shapes the ilink fork actually emits:
///
/// ```
/// #EXTM3U
/// #PLAYLIST:Online radio: JAZZ Music (...)
/// #EXTINF:-1 tvg-logo="https://..." group-title="JAZZ Radio", Name - 128
/// http://host:8000/stream
/// ```
///
/// …as well as the bare `#EXTINF:-1, Name` form, CRLF endings, blank and
/// comment lines, attribute-only-or-no-attribute EXTINF, and stray URL
/// lines with no preceding EXTINF. Malformed entries are skipped, never
/// thrown — a single bad line in a 10k-entry file must not blank the
/// screen.
List<Station> parseM3u(String body, {int cap = kDefaultStationCap}) {
  if (body.isEmpty || cap <= 0) return const [];

  final out = <Station>[];
  final seenIds = <String>{};

  // Pending EXTINF metadata, consumed by the next URL line. Reset whenever
  // a second EXTINF arrives before a URL (the first entry had no stream).
  String? pendingName;
  String? pendingLogo;
  String? pendingGroup;
  int pendingBitrate = 0;
  var havePending = false;

  // `\n` split also handles `\r\n` — we trim the trailing `\r` per line.
  for (final rawLine in body.split('\n')) {
    if (out.length >= cap) break;
    final line = rawLine.replaceFirst(_trailingCr, '').trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXTINF')) {
        final ext = _parseExtInf(line);
        pendingName = ext.name;
        pendingLogo = ext.logo;
        pendingGroup = ext.group;
        pendingBitrate = ext.bitrate;
        havePending = true;
      }
      // #EXTM3U, #PLAYLIST, #EXTGRP and any other directive: ignore.
      continue;
    }

    // Non-comment, non-blank line → a stream URL. Only absolute http(s)
    // streams are playable here; relative paths in the source-folder
    // playlists are intentionally rejected (root files are absolute).
    final url = line;
    if (!_isHttpUrl(url)) {
      havePending = false;
      continue;
    }
    final id = StationIdentity.forStreamUrl(url);
    if (id.isEmpty || !seenIds.add(id)) {
      // Empty id (blank url) or a duplicate stream — keep the first.
      havePending = false;
      continue;
    }

    out.add(
      Station(
        id: id,
        sourceUuid: '',
        // A URL with no preceding EXTINF still yields a usable tile —
        // fall back to the host so the row isn't blank.
        name: (havePending && pendingName != null && pendingName.isNotEmpty)
            ? pendingName
            : _hostOf(url),
        streamUrl: url,
        favicon: (pendingLogo != null && pendingLogo.isNotEmpty)
            ? pendingLogo
            : null,
        tags: (pendingGroup != null && pendingGroup.isNotEmpty)
            ? <String>[pendingGroup]
            : const [],
        bitrate: pendingBitrate,
        isHls: url.contains('.m3u8'),
      ),
    );

    pendingName = null;
    pendingLogo = null;
    pendingGroup = null;
    pendingBitrate = 0;
    havePending = false;
  }

  return List<Station>.unmodifiable(out);
}

/// Top-level single-arg entry point for `compute()` — Flutter's isolate
/// helper requires a top-level/static `R Function(Q)`, so it can't pass
/// the named `cap`. Applies [kDefaultStationCap].
List<Station> parseM3uIsolate(String body) => parseM3u(body);

final RegExp _trailingCr = RegExp(r'\r$');
final RegExp _logoAttr = RegExp('tvg-logo="([^"]*)"', caseSensitive: false);
final RegExp _groupAttr = RegExp('group-title="([^"]*)"', caseSensitive: false);

/// Trailing ` - 128` / ` - 128 kbps` bitrate suffix. Deliberately
/// conservative: requires the surrounding ` - ` spacing and a 2–3 digit
/// number so a legitimate station name like "Rock - The Classics" keeps
/// its full title instead of losing "Classics" to a phantom bitrate.
final RegExp _bitrateSuffix = RegExp(
  r'\s-\s(\d{2,3})(?:\s*(?:kbps|kbit/s|k))?\s*$',
  caseSensitive: false,
);

class _ExtInf {
  const _ExtInf(this.name, this.logo, this.group, this.bitrate);
  final String name;
  final String? logo;
  final String? group;
  final int bitrate;
}

_ExtInf _parseExtInf(String line) {
  // `#EXTINF:<duration>[ attrs],<title>` — the title starts after the
  // first comma that is NOT inside a double-quoted attribute value
  // (logo/group URLs can themselves contain commas).
  var inQuotes = false;
  var commaIdx = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x22) {
      inQuotes = !inQuotes;
    } else if (c == 0x2C && !inQuotes) {
      commaIdx = i;
      break;
    }
  }

  final attrs = commaIdx >= 0 ? line.substring(0, commaIdx) : line;
  var title = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : '';

  final logo = _logoAttr.firstMatch(attrs)?.group(1)?.trim();
  final group = _groupAttr.firstMatch(attrs)?.group(1)?.trim();

  var bitrate = 0;
  final bm = _bitrateSuffix.firstMatch(title);
  if (bm != null) {
    final n = int.tryParse(bm.group(1)!) ?? 0;
    // Plausible stream-bitrate band — outside it, the digits are almost
    // certainly part of the name (e.g. "Studio 100").
    if (n >= 32 && n <= 512) {
      bitrate = n;
      title = title.substring(0, bm.start).trim();
    }
  }

  return _ExtInf(title, logo, group, bitrate);
}

bool _isHttpUrl(String s) =>
    s.startsWith('http://') || s.startsWith('https://');

String _hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.isEmpty ? 'Unknown station' : h;
}
