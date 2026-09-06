import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'station.dart';

/// Where a user-imported playlist came from.
///
/// Persisted alongside the playlist so the UI can show a sensible
/// "imported from …" hint and so URL-sourced lists can be re-fetched on
/// refresh. Sealed so the importer + UI can exhaustively switch and a
/// future variant (e.g. content-URI from Android SAF) is a one-class
/// addition rather than a stringly-typed enum bump.
sealed class UserPlaylistSource {
  const UserPlaylistSource();

  factory UserPlaylistSource.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    return switch (kind) {
      'file' => UserPlaylistFileSource(j['path'] as String),
      'url' => UserPlaylistUrlSource(j['url'] as String),
      _ => throw FormatException('unknown source kind: $kind'),
    };
  }

  Map<String, dynamic> toJson();

  /// Short human-readable form for the UI (e.g. "file: arabic.m3u" or
  /// "url: https://…").
  String get displayHint;
}

class UserPlaylistFileSource extends UserPlaylistSource {
  const UserPlaylistFileSource(this.path);
  final String path;

  @override
  Map<String, dynamic> toJson() => {'kind': 'file', 'path': path};

  @override
  String get displayHint {
    final tail = path.split(RegExp(r'[\\/]')).last;
    return 'file: ${tail.isEmpty ? path : tail}';
  }

  @override
  bool operator ==(Object other) =>
      other is UserPlaylistFileSource && other.path == path;
  @override
  int get hashCode => Object.hash('file', path);
}

class UserPlaylistUrlSource extends UserPlaylistSource {
  const UserPlaylistUrlSource(this.url);
  final String url;

  @override
  Map<String, dynamic> toJson() => {'kind': 'url', 'url': url};

  @override
  String get displayHint => 'url: $url';

  @override
  bool operator ==(Object other) =>
      other is UserPlaylistUrlSource && other.url == url;
  @override
  int get hashCode => Object.hash('url', url);
}

/// A user-imported radio playlist: a named, persisted collection of
/// [Station]s plus the metadata needed to display and refresh it.
///
/// Snapshots are persisted in full (the same model favourites use) so
/// playback works offline once imported, and so a corrupt or
/// disappearing source (URL 404, file deleted) doesn't break what the
/// user already has.
class UserPlaylist {
  const UserPlaylist({
    required this.id,
    required this.name,
    required this.source,
    required this.importedAt,
    this.lastRefreshedAt,
    required this.stations,
  });

  factory UserPlaylist.fromJson(Map<String, dynamic> j) => UserPlaylist(
    id: j['id'] as String,
    name: j['name'] as String,
    source: UserPlaylistSource.fromJson(j['source'] as Map<String, dynamic>),
    importedAt: DateTime.parse(j['imported_at'] as String),
    lastRefreshedAt: j['last_refreshed_at'] is String
        ? DateTime.parse(j['last_refreshed_at'] as String)
        : null,
    stations: ((j['stations'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Station.fromJson)
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source.toJson(),
    'imported_at': importedAt.toIso8601String(),
    if (lastRefreshedAt != null)
      'last_refreshed_at': lastRefreshedAt!.toIso8601String(),
    'stations': stations.map((s) => s.toJson()).toList(growable: false),
  };

  /// Returns a copy with refreshed contents — used by the importer when
  /// the user hits "Refresh" on a URL-sourced playlist.
  UserPlaylist withRefresh({
    required DateTime at,
    required List<Station> stations,
  }) => UserPlaylist(
    id: id,
    name: name,
    source: source,
    importedAt: importedAt,
    lastRefreshedAt: at,
    stations: stations,
  );

  final String id;
  final String name;
  final UserPlaylistSource source;
  final DateTime importedAt;
  final DateTime? lastRefreshedAt;
  final List<Station> stations;

  int get entryCount => stations.length;

  /// Stable id from `name + importedAt`. Two playlists imported from
  /// the same source at different times deliberately get distinct ids
  /// (importing twice means the user wants two entries). sha1 because
  /// it's already in deps via [StationIdentity] and is collision-safe
  /// for the user-bounded size of this set.
  static String newId(String name, DateTime importedAt) {
    final raw = '$name|${importedAt.millisecondsSinceEpoch}';
    return sha1.convert(utf8.encode(raw)).toString();
  }
}
