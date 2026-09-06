/// A native Android package in the local installed-app library.
/// Name and installed version come from PackageManager; APK import is an
/// explicit owner-selected local file checked by LocalApkImporter.
library;

class NativeApp {
  const NativeApp({
    required this.packageId,
    required this.displayName,
    required this.description,
    required this.latestVersionCode,
    required this.latestVersionName,
    this.category,
    this.iconUrl,
    this.screenshots = const <String>[],
    this.installedVersionCode,
  });

  /// Android package id (e.g. `com.acme.dashcam`) — the stable key.
  final String packageId;

  /// Locale code (`ar`, `en`, …) → display name. May be empty when the
  /// publisher shipped no copy; [localizedName] then falls back to the
  /// package id so a row is never nameless.
  final Map<String, String> displayName;

  /// Same shape as [displayName]; may be empty.
  final Map<String, String> description;

  /// versionCode of the app's current production release.
  final int latestVersionCode;

  /// Human version string of the current production release.
  final String latestVersionName;

  /// Free-form grouping key from the catalog row (nullable).
  final String? category;

  /// Absolute icon URL (CDN). Rendered via `MiniAppRemoteImage` which
  /// sniffs SVG vs raster. Nullable — the UI shows a neutral fallback.
  final String? iconUrl;

  /// Pre-install screenshot gallery (absolute URLs, publisher order).
  final List<String> screenshots;

  /// versionCode currently installed on this device, or null when the
  /// package isn't installed. Derived (merged from `pkg.list`), never
  /// from the remote catalog.
  final int? installedVersionCode;

  /// True when the package is present on the device.
  bool get isInstalled => installedVersionCode != null;

  /// True when a newer production release exists than what's installed.
  bool get hasUpdate =>
      installedVersionCode != null && latestVersionCode > installedVersionCode!;

  /// Best-matching localized name: exact locale → English → first value.
  /// When the publisher shipped no copy at all, fall back to a friendly
  /// title derived from the package id's last segment ("com.acme.dashcam"
  /// → "Dashcam") rather than the raw dotted id — a nameless or
  /// dotted-id row reads as broken to an owner browsing the store.
  String localizedName(String languageCode) {
    final picked = _pick(displayName, languageCode);
    return picked.isEmpty ? _friendlyFromPackageId(packageId) : picked;
  }

  String localizedDescription(String languageCode) =>
      _pick(description, languageCode);

  /// "com.acme.dash_cam" → "Dash cam". Best-effort: take the last
  /// dot-segment, split snake/camel boundaries, Title-case words.
  static String _friendlyFromPackageId(String pkg) {
    final segments = pkg.split('.').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return pkg;
    final last = segments.last
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .trim();
    if (last.isEmpty) return pkg;
    return last
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  static String _pick(Map<String, String> map, String languageCode) {
    if (map.isEmpty) return '';
    final exact = map[languageCode];
    if (exact != null && exact.isNotEmpty) return exact;
    final english = map['en'];
    if (english != null && english.isNotEmpty) return english;
    return map.values.first;
  }

  /// Returns a copy with the derived install-state stamped on. The store
  /// controller calls this with the `pkg.list` lookup result; the rest
  /// of the row is owned by the remote catalog and isn't mutated.
  NativeApp withInstalledVersion(int? installedVersionCode) => NativeApp(
    packageId: packageId,
    displayName: displayName,
    description: description,
    latestVersionCode: latestVersionCode,
    latestVersionName: latestVersionName,
    category: category,
    iconUrl: iconUrl,
    screenshots: screenshots,
    installedVersionCode: installedVersionCode,
  );

  /// Parse one `manifest_summary()` row from the catalog response. Only
  /// approved+production rows reach here, so [latestVersionCode] /
  /// [latestVersionName] are expected present; defaults keep a partial
  /// row from throwing.
  factory NativeApp.fromJson(Map<String, dynamic> json) {
    return NativeApp(
      packageId: (json['packageId'] as String?) ?? '',
      displayName: _localeMap(json['displayName']),
      description: _localeMap(json['description']),
      latestVersionCode: (json['latestVersionCode'] as num?)?.toInt() ?? 0,
      latestVersionName: (json['latestVersionName'] as String?) ?? '',
      category: json['category'] as String?,
      iconUrl: json['iconUrl'] as String?,
      screenshots: _stringList(json['screenshots']),
    );
  }

  static Map<String, String> _localeMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final out = <String, String>{};
    raw.forEach((k, v) {
      if (k is String && v is String) out[k] = v;
    });
    return out;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }
}
