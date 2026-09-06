import 'channel.dart';

/// One group in the catalogue `index.json` — what the chip row lists.
///
/// Wire shape (from `dist/index.json`):
/// ```json
/// { "kind":"country", "code":"AE", "name":"United Arab Emirates",
///   "flag":"🇦🇪", "count":38, "path":"channels/country/ae.json" }
/// { "kind":"category", "id":"news", "name":"News", "count":200,
///   "path":"channels/category/news.json" }
/// ```
class TvCatalogGroup {
  const TvCatalogGroup({
    required this.kind,
    required this.key,
    required this.name,
    required this.count,
    required this.path,
    this.flag,
  });

  factory TvCatalogGroup.fromJson(Map<String, dynamic> j) {
    final kind = (j['kind'] as String?)?.trim() ?? '';
    // Country groups key on `code`, category groups on `id`.
    final key = (kind == 'country' ? j['code'] : j['id']) as String? ?? '';
    return TvCatalogGroup(
      kind: kind,
      key: key,
      name: (j['name'] as String?)?.trim() ?? key,
      count: (j['count'] as num?)?.toInt() ?? 0,
      path: (j['path'] as String?)?.trim() ?? '',
      flag: j['flag'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (kind == 'country') 'code': key else 'id': key,
    'name': name,
    'count': count,
    'path': path,
    'flag': flag,
  };

  /// `'country'` | `'category'`.
  final String kind;

  /// Country code (lowercased addressing) or category id.
  final String key;
  final String name;
  final int count;
  final String? flag;

  /// Path under the catalogue root, e.g. `channels/country/ae.json`.
  final String path;

  /// Stable id for cache addressing + picker selection: `country:ae`.
  String get id => '$kind:$key';
}

/// The `index.json` payload — the list of browsable groups.
class TvCatalogIndex {
  const TvCatalogIndex({required this.generatedAt, required this.groups});

  factory TvCatalogIndex.fromJson(Map<String, dynamic> j) {
    final at = j['generatedAt'] as String? ?? '';
    return TvCatalogIndex(
      generatedAt:
          DateTime.tryParse(at) ?? DateTime.fromMillisecondsSinceEpoch(0),
      groups: ((j['groups'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TvCatalogGroup.fromJson)
          .where((g) => g.key.isNotEmpty && g.path.isNotEmpty)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'generatedAt': generatedAt.toIso8601String(),
    'groups': groups.map((g) => g.toJson()).toList(growable: false),
  };

  final DateTime generatedAt;
  final List<TvCatalogGroup> groups;

  List<TvCatalogGroup> get countries =>
      groups.where((g) => g.kind == 'country').toList(growable: false);
  List<TvCatalogGroup> get categories =>
      groups.where((g) => g.kind == 'category').toList(growable: false);
}

/// A fully-materialised group (its meta + parsed channels). Identity is the
/// group's [id] so the cache + UI correlate without keeping a ref to the
/// index entry.
class TvChannelGroup {
  const TvChannelGroup({
    required this.id,
    required this.name,
    required this.channels,
  });

  factory TvChannelGroup.fromJson(Map<String, dynamic> j) => TvChannelGroup(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    channels: ((j['channels'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Channel.fromJson)
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'channels': channels.map((c) => c.toJson()).toList(growable: false),
  };

  final String id;
  final String name;
  final List<Channel> channels;

  int get channelCount => channels.length;
}
