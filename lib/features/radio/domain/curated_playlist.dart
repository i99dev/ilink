import 'radio_facet.dart';
import 'station.dart';

/// One entry in the curated `index.json` — what the picker lists.
///
/// Wire shape (verbatim from the curated catalogue `api/index.json`):
/// ```json
/// { "name": "Arabic", "url": "api/playlists/arabic.json", "count": 1361 }
/// ```
/// `id` is the lowercased display name — stable enough as a picker key,
/// and useful for case-insensitive dedupe / cache addressing without
/// re-hashing.
class CuratedIndexEntry {
  const CuratedIndexEntry({
    required this.id,
    required this.name,
    required this.count,
    required this.urlPath,
  });

  factory CuratedIndexEntry.fromJson(Map<String, dynamic> j) {
    final name = (j['name'] as String?)?.trim() ?? '';
    return CuratedIndexEntry(
      id: name.toLowerCase(),
      name: name,
      count: (j['count'] as num?)?.toInt() ?? 0,
      urlPath: (j['url'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': urlPath,
    'count': count,
  };

  /// Lowercased display name — stable picker key.
  final String id;

  /// User-facing label exactly as the catalogue ships it.
  final String name;

  /// Number of streams in the playlist (per the index — the actual
  /// fetch may yield fewer after dedupe + http-only filtering).
  final int count;

  /// Path under the API root, e.g. `api/playlists/arabic.json`.
  final String urlPath;

  /// Facet this entry belongs to, parsed once from the `"<Facet>: <Value>"`
  /// name the catalogue ships. See [RadioFacet] for the contract.
  RadioFacet get facet => RadioFacet.split(name).$1;

  /// Display label with the facet prefix stripped (`"France"`, `"Jazz"`).
  /// Falls back to the full name when there's no recognised prefix.
  String get label => RadioFacet.split(name).$2;
}

/// One facet's slice of the catalogue — the [facet] plus its entries, already
/// bucketed. Built once per index via [CuratedIndex.facetGroups] so the picker
/// (and any future browse-by-facet UI) switches facets in O(1) instead of
/// re-scanning the whole catalogue on every tap/keystroke.
class FacetGroup {
  const FacetGroup({required this.facet, required this.entries});

  final RadioFacet facet;
  final List<CuratedIndexEntry> entries;

  int get count => entries.length;
}

/// The full `index.json` payload (a small wrapper around the list of
/// entries — kept as a class for the timestamp + a future totalPlaylists
/// counter if it ever matters).
class CuratedIndex {
  const CuratedIndex({required this.generatedAt, required this.entries});

  factory CuratedIndex.fromJson(Map<String, dynamic> j) {
    final at = j['generatedAt'] as String? ?? '';
    return CuratedIndex(
      generatedAt:
          DateTime.tryParse(at) ?? DateTime.fromMillisecondsSinceEpoch(0),
      entries: ((j['playlists'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CuratedIndexEntry.fromJson)
          .where((e) => e.name.isNotEmpty && e.urlPath.isNotEmpty)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'generatedAt': generatedAt.toIso8601String(),
    'playlists': entries.map((e) => e.toJson()).toList(growable: false),
  };

  final DateTime generatedAt;
  final List<CuratedIndexEntry> entries;

  /// Bucket [entries] by [RadioFacet] in a single pass, returning only the
  /// facets that actually have content, in [RadioFacet.order]. Entry order
  /// within a group is preserved (the catalogue ships alphabetically sorted).
  List<FacetGroup> facetGroups() {
    final buckets = <RadioFacet, List<CuratedIndexEntry>>{};
    for (final e in entries) {
      (buckets[e.facet] ??= <CuratedIndexEntry>[]).add(e);
    }
    return [
      for (final f in RadioFacet.order)
        if (buckets[f]?.isNotEmpty ?? false)
          FacetGroup(facet: f, entries: List.unmodifiable(buckets[f]!)),
    ];
  }
}

/// A fully-materialised curated playlist (entry + its parsed stations).
/// Identity is the entry's `id` so the cache + UI can correlate without
/// keeping a separate ref to the index entry around.
class CuratedPlaylist {
  const CuratedPlaylist({
    required this.id,
    required this.name,
    required this.stations,
  });

  /// JSON round-trip is supported so the cache can persist the parsed
  /// form (already-resolved Station list) instead of re-parsing on
  /// every cold start.
  factory CuratedPlaylist.fromJson(Map<String, dynamic> j) => CuratedPlaylist(
    id: j['id'] as String,
    name: j['name'] as String,
    stations: ((j['stations'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Station.fromJson)
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'stations': stations.map((s) => s.toJson()).toList(growable: false),
  };

  final String id;
  final String name;
  final List<Station> stations;

  int get entryCount => stations.length;
}

/// Resolve a spoken query (e.g. "jazz", "france", "arabic music") to the best
/// curated playlist in [index] for voice "play …". Matches the facet VALUE
/// ([CuratedIndexEntry.label] — "Category: Jazz" → "jazz"): an exact value
/// wins, then a value that contains the query, then the full prefixed name.
/// Pure + side-effect-free so it's unit-tested without the network. Null when
/// nothing reasonable matches.
CuratedIndexEntry? matchCuratedEntry(CuratedIndex index, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  CuratedIndexEntry? contains;
  for (final e in index.entries) {
    final label = e.label.toLowerCase();
    if (label == q) return e; // exact facet value — strongest signal
    contains ??= (label.contains(q) || e.name.toLowerCase().contains(q))
        ? e
        : null;
  }
  return contains;
}

/// Pick a station from a loaded [pl] for a spoken query: prefer one whose
/// name contains the query, else the first station. Null only when the
/// playlist is empty.
Station? pickCuratedStation(CuratedPlaylist pl, String query) {
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    for (final s in pl.stations) {
      if (s.name.toLowerCase().contains(q)) return s;
    }
  }
  return pl.stations.isEmpty ? null : pl.stations.first;
}
