/// Typed parsing of voice-tool result payloads → one model per tool that
/// its panel renders. Centralizes payload-key handling in one pure,
/// unit-testable place so the widgets stay declarative and a backend key
/// rename is caught by a test, not by a blank panel on the head unit.
///
/// Every result carries [ResultStatus.degraded] + [ResultStatus.message]
/// (the backend's standard soft-failure envelope), parsed once via
/// [ResultStatus.fromArgs] instead of being re-read in each `build()`.
library;

/// Shared soft-failure envelope every tool result embeds.
class ResultStatus {
  const ResultStatus({required this.degraded, this.message});

  final bool degraded;
  final String? message;

  static ResultStatus fromArgs(Map<String, dynamic> a) => ResultStatus(
    degraded: a['degraded'] == true,
    message: a['message'] as String?,
  );
}

/// num/string-tolerant coercion shared by every model.
double? _d(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
int? _i(Object? v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
// Rounded (not truncated) — for display temperatures the backend may
// send as fractional degrees (31.6 -> 32, matching the old widget).
int? _round(Object? v) =>
    v is num ? v.round() : (v is String ? double.tryParse(v)?.round() : null);
String? _s(Object? v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

// ---------------------------------------------------------------------------
// Places (find_nearby / find_place)
// ---------------------------------------------------------------------------

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.lat,
    required this.lng,
    this.distanceM,
    this.address,
    this.rating,
    this.ratingCount,
    this.openNow,
  });

  final String name;
  final double lat;
  final double lng;
  final int? distanceM;
  final String? address;
  final double? rating;
  final int? ratingCount;
  final bool? openNow;

  /// "350 m" / "2.4 km" — compact distance for chips. Null when unknown.
  String? get distanceLabel {
    final m = distanceM;
    if (m == null) return null;
    return m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km';
  }

  /// Parse one ``results[]`` entry; null when it lacks the required
  /// name + coordinates (mirrors the backend parser's filtering).
  static PlaceResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final lat = _d(raw['latitude']);
    final lng = _d(raw['longitude']);
    if (name == null || name.isEmpty || lat == null || lng == null) return null;
    return PlaceResult(
      name: name,
      lat: lat,
      lng: lng,
      distanceM: _i(raw['distance_m']),
      address: _s(raw['address']),
      rating: _d(raw['rating']),
      ratingCount: _i(raw['rating_count']),
      openNow: raw['open_now'] is bool ? raw['open_now'] as bool : null,
    );
  }

  /// Parse the ``results`` list from a find_nearby / find_place payload.
  static List<PlaceResult> listFrom(Object? results) {
    if (results is! List) return const [];
    return results
        .map(PlaceResult.fromJson)
        .whereType<PlaceResult>()
        .toList(growable: false);
  }
}

/// The whole find_nearby / find_place payload.
class PlacesResult {
  const PlacesResult({
    required this.status,
    required this.title,
    required this.query,
    required this.places,
  });

  final ResultStatus status;
  final String title;

  /// Free-text the "show all on map" search uses (category/query/title),
  /// with underscores normalized to spaces.
  final String query;
  final List<PlaceResult> places;

  bool get isEmpty => status.degraded || places.isEmpty;

  static PlacesResult fromArgs(Map<String, dynamic> a) {
    final title = _s(a['title']) ?? 'Nearby';
    final rawQuery = _s(a['category']) ?? _s(a['query']) ?? title;
    return PlacesResult(
      status: ResultStatus.fromArgs(a),
      title: title,
      query: rawQuery.replaceAll('_', ' '),
      places: PlaceResult.listFrom(a['results']),
    );
  }
}

// ---------------------------------------------------------------------------
// Route (get_route)
// ---------------------------------------------------------------------------

class RouteResult {
  const RouteResult({
    required this.status,
    required this.destination,
    this.durationText,
    this.distanceText,
    this.trafficDelayMin,
    this.rangeOk,
    this.rangeWarning,
    this.lat,
    this.lng,
  });

  final ResultStatus status;
  final String destination;
  final String? durationText;
  final String? distanceText;
  final int? trafficDelayMin;
  final bool? rangeOk;
  final String? rangeWarning;
  final double? lat;
  final double? lng;

  /// Worth surfacing a traffic banner (small delays are noise).
  bool get hasTrafficDelay => (trafficDelayMin ?? 0) >= 3;
  bool get hasCoords => lat != null && lng != null;

  static RouteResult fromArgs(Map<String, dynamic> a) => RouteResult(
    status: ResultStatus.fromArgs(a),
    destination: _s(a['destination']) ?? 'Destination',
    durationText: _s(a['duration_text']),
    distanceText: _s(a['distance_text']),
    trafficDelayMin: _i(a['traffic_delay_minutes']),
    rangeOk: a['range_ok'] is bool ? a['range_ok'] as bool : null,
    rangeWarning: _s(a['range_warning']),
    lat: _d(a['destination_latitude']),
    lng: _d(a['destination_longitude']),
  );
}

// ---------------------------------------------------------------------------
// Navigate (navigate_to)
// ---------------------------------------------------------------------------

class NavigateResult {
  const NavigateResult({
    required this.status,
    required this.label,
    this.lat,
    this.lng,
  });

  final ResultStatus status;
  final String label;
  final double? lat;
  final double? lng;

  /// Ready to hand off to the nav app.
  bool get canLaunch => !status.degraded && lat != null && lng != null;

  static NavigateResult fromArgs(Map<String, dynamic> a) => NavigateResult(
    status: ResultStatus.fromArgs(a),
    label: _s(a['label']) ?? 'Destination',
    lat: _d(a['latitude']),
    lng: _d(a['longitude']),
  );
}

// ---------------------------------------------------------------------------
// Weather (get_weather)
// ---------------------------------------------------------------------------

class WeatherHour {
  const WeatherHour({required this.label, this.tempC});

  /// "14:00" — the hour clipped from an ISO-ish timestamp.
  final String label;
  final int? tempC;

  static WeatherHour? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['time']?.toString() ?? '';
    final hhmm = t.contains('T') ? t.split('T').last : t;
    final label = hhmm.length >= 5 ? hhmm.substring(0, 5) : hhmm;
    return WeatherHour(label: label, tempC: _round(raw['temperature_c']));
  }
}

class WeatherResult {
  const WeatherResult({
    required this.status,
    required this.condition,
    this.tempC,
    this.windKmh,
    this.highC,
    this.lowC,
    this.footer,
    this.weatherCode,
    this.hours = const [],
  });

  final ResultStatus status;
  final String condition;
  final int? tempC;
  final int? windKmh;
  final int? highC;
  final int? lowC;
  final String? footer;
  final int? weatherCode;
  final List<WeatherHour> hours;

  static WeatherResult fromArgs(Map<String, dynamic> a) {
    final raw = a['next_hours'];
    final hours = raw is List
        ? raw
              .map(WeatherHour.fromJson)
              .whereType<WeatherHour>()
              .toList(growable: false)
        : const <WeatherHour>[];
    return WeatherResult(
      status: ResultStatus.fromArgs(a),
      condition: _s(a['condition']) ?? _s(a['title']) ?? 'Weather',
      tempC: _round(a['temperature_c']),
      windKmh: _round(a['wind_kmh']),
      highC: _round(a['temperature_high_c']),
      lowC: _round(a['temperature_low_c']),
      footer: _s(a['footer']),
      weatherCode: _i(a['weather_code']),
      hours: hours,
    );
  }
}

// ---------------------------------------------------------------------------
// Translate (translate)
// ---------------------------------------------------------------------------

class TranslateResult {
  const TranslateResult({
    required this.status,
    this.sourceText,
    this.translatedText,
    this.targetLanguage,
    this.detectedLanguage,
  });

  final ResultStatus status;
  final String? sourceText;
  final String? translatedText;
  final String? targetLanguage;
  final String? detectedLanguage;

  /// "EN → AR" / "AR" — language pair for the header subtitle.
  String? get languagePair {
    if (detectedLanguage != null && targetLanguage != null) {
      return '$detectedLanguage → $targetLanguage';
    }
    return targetLanguage;
  }

  static TranslateResult fromArgs(Map<String, dynamic> a) => TranslateResult(
    status: ResultStatus.fromArgs(a),
    sourceText: _s(a['source_text']),
    translatedText: _s(a['translated_text']),
    targetLanguage: _s(a['target_language'])?.toUpperCase(),
    detectedLanguage: _s(a['detected_language'])?.toUpperCase(),
  );
}
