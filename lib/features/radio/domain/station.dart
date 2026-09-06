/// A radio station record as served by our backend at /api/v1/radio.
///
/// Plain immutable value class — no codegen (freezed/json_serializable not
/// in this project's toolchain). Equality is identity-based via `id` to
/// keep `==` O(1) for Riverpod's change detection.
///
/// `toJson` is present so we can persist a cached station in
/// shared_preferences; the shape matches the backend's wire format so the
/// same `fromJson` parses both server and cache payloads.
class Station {
  const Station({
    required this.id,
    required this.sourceUuid,
    required this.name,
    required this.streamUrl,
    this.homepage,
    this.favicon,
    this.countryCode,
    this.countryName,
    this.state,
    this.language,
    this.languageCodes = const [],
    this.tags = const [],
    this.codec,
    this.bitrate = 0,
    this.isHls = false,
    this.votes = 0,
    this.clickCount = 0,
  });

  factory Station.fromJson(Map<String, dynamic> json) => Station(
    id: json['id'] as String,
    sourceUuid: json['source_uuid'] as String? ?? '',
    name: json['name'] as String? ?? '',
    streamUrl: json['stream_url'] as String? ?? '',
    homepage: json['homepage'] as String?,
    favicon: json['favicon'] as String?,
    countryCode: json['country_code'] as String?,
    countryName: json['country_name'] as String?,
    state: json['state'] as String?,
    language: json['language'] as String?,
    languageCodes:
        (json['language_codes'] as List?)?.cast<String>() ?? const [],
    tags: (json['tags'] as List?)?.cast<String>() ?? const [],
    codec: json['codec'] as String?,
    bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
    isHls: json['is_hls'] as bool? ?? false,
    votes: (json['votes'] as num?)?.toInt() ?? 0,
    clickCount: (json['click_count'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String sourceUuid;
  final String name;
  final String streamUrl;
  final String? homepage;
  final String? favicon;
  final String? countryCode;
  final String? countryName;
  final String? state;
  final String? language;
  final List<String> languageCodes;
  final List<String> tags;
  final String? codec;
  final int bitrate;
  final bool isHls;
  final int votes;
  final int clickCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source_uuid': sourceUuid,
    'name': name,
    'stream_url': streamUrl,
    'homepage': homepage,
    'favicon': favicon,
    'country_code': countryCode,
    'country_name': countryName,
    'state': state,
    'language': language,
    'language_codes': languageCodes,
    'tags': tags,
    'codec': codec,
    'bitrate': bitrate,
    'is_hls': isHls,
    'votes': votes,
    'click_count': clickCount,
  };

  @override
  bool operator ==(Object other) => other is Station && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
