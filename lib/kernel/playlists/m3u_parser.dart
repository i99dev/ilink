import 'm3u_entry.dart';

/// Hard upper bound on entries materialised from a single playlist body.
///
/// The scalability lever: everything downstream of the parser (memory, the
/// cached JSON blob, the in-memory search filter, the lazily-built grid) is
/// then O(≤cap) forever, independent of how large an imported file or
/// upstream playlist grows.
const int kDefaultEntryCap = 5000;

/// Pure, isolate-safe M3U → [M3uEntry] parser. No IO, no platform handles,
/// no `dart:io` — so it can be handed straight to `compute()` for large
/// bodies (see [parseM3uEntriesIsolate]).
///
/// Tolerates the shapes real playlists emit:
///
/// ```
/// #EXTM3U
/// #EXTINF:-1 tvg-id="BBCNews.uk" tvg-logo="https://…" group-title="News",BBC News
/// #EXTVLCOPT:http-referrer=https://example.com/
/// #EXTVLCOPT:http-user-agent=Mozilla/5.0
/// https://host/index.m3u8
/// ```
///
/// …as well as the bare `#EXTINF:-1,Name` form, a trailing `#EXTGRP:News`
/// directive, CRLF endings, blank/comment lines, and stray URL lines with no
/// preceding `#EXTINF`. Malformed entries are skipped, never thrown — one
/// bad line in a 10k-entry file must not blank the screen. Entries are
/// deduped by stream URL (first wins).
List<M3uEntry> parseM3uEntries(String body, {int cap = kDefaultEntryCap}) {
  if (body.isEmpty || cap <= 0) return const [];

  final out = <M3uEntry>[];
  final seenUrls = <String>{};

  // Pending metadata, consumed by the next URL line. Reset whenever a
  // second EXTINF arrives before a URL (the first entry had no stream).
  String? pendingName;
  String? pendingTvgId;
  String? pendingLogo;
  String? pendingGroup;
  String? pendingReferrer;
  String? pendingUserAgent;
  Map<String, String> pendingAttrs = const {};
  var havePending = false;

  void resetPending() {
    pendingName = null;
    pendingTvgId = null;
    pendingLogo = null;
    pendingGroup = null;
    pendingReferrer = null;
    pendingUserAgent = null;
    pendingAttrs = const {};
    havePending = false;
  }

  // `\n` split also handles `\r\n` — we strip the trailing `\r` per line.
  for (final rawLine in body.split('\n')) {
    if (out.length >= cap) break;
    final line = rawLine.replaceFirst(_trailingCr, '').trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXTINF')) {
        final ext = _parseExtInf(line);
        pendingName = ext.name;
        pendingTvgId = ext.attributes['tvg-id'];
        pendingLogo = ext.attributes['tvg-logo'];
        pendingGroup = ext.attributes['group-title'];
        pendingAttrs = ext.attributes;
        pendingReferrer = null;
        pendingUserAgent = null;
        havePending = true;
      } else if (line.startsWith('#EXTVLCOPT:')) {
        final opt = line.substring('#EXTVLCOPT:'.length);
        final eq = opt.indexOf('=');
        if (eq > 0) {
          final key = opt.substring(0, eq).trim().toLowerCase();
          final value = opt.substring(eq + 1).trim();
          if (key == 'http-referrer') pendingReferrer = value;
          if (key == 'http-user-agent') pendingUserAgent = value;
        }
      } else if (line.startsWith('#EXTGRP:')) {
        // Fallback group when EXTINF carried no group-title.
        pendingGroup ??= line.substring('#EXTGRP:'.length).trim();
      }
      // #EXTM3U, #PLAYLIST, #EXTHTTP and any other directive: ignore.
      continue;
    }

    // Non-comment, non-blank line → a stream URL. Only absolute http(s)
    // streams are playable.
    final url = line;
    if (!_isHttpUrl(url)) {
      resetPending();
      continue;
    }
    if (!seenUrls.add(url)) {
      // Duplicate stream — keep the first.
      resetPending();
      continue;
    }

    out.add(
      M3uEntry(
        url: url,
        name: (havePending && pendingName != null && pendingName!.isNotEmpty)
            ? pendingName!
            : _hostOf(url),
        tvgId: _nullIfEmpty(pendingTvgId),
        logo: _nullIfEmpty(pendingLogo),
        group: _nullIfEmpty(pendingGroup),
        attributes: pendingAttrs,
        referrer: _nullIfEmpty(pendingReferrer),
        userAgent: _nullIfEmpty(pendingUserAgent),
      ),
    );
    resetPending();
  }

  return List<M3uEntry>.unmodifiable(out);
}

/// Top-level single-arg entry point for `compute()` — applies the default
/// cap (Flutter's isolate helper can't pass the named `cap`).
List<M3uEntry> parseM3uEntriesIsolate(String body) => parseM3uEntries(body);

final RegExp _trailingCr = RegExp(r'\r$');
final RegExp _attrPair = RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"');

class _ExtInf {
  const _ExtInf(this.name, this.attributes);
  final String name;
  final Map<String, String> attributes;
}

_ExtInf _parseExtInf(String line) {
  // `#EXTINF:<duration>[ attrs],<title>` — the title starts after the first
  // comma that is NOT inside a double-quoted attribute value (logo/group
  // URLs can themselves contain commas).
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

  final attrsPart = commaIdx >= 0 ? line.substring(0, commaIdx) : line;
  final title = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : '';

  final attributes = <String, String>{};
  for (final m in _attrPair.allMatches(attrsPart)) {
    attributes[m.group(1)!.toLowerCase()] = m.group(2)!.trim();
  }
  return _ExtInf(title, attributes);
}

bool _isHttpUrl(String s) =>
    s.startsWith('http://') || s.startsWith('https://');

String? _nullIfEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

String _hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.isEmpty ? 'Unknown channel' : h;
}
