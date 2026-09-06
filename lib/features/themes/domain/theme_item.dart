import '../../../kernel/ui/theme/theme_spec.dart';
import '../../mini_apps/domain/mini_app_compat.dart';

/// Release track for a catalog theme row. Mirrors `MiniAppTrack` —
/// production rows omit the field (defaults to [production]); a
/// `/themes/me` row may carry `beta` for an enrolled tester.
enum ThemeTrack {
  production,
  beta;

  static ThemeTrack fromWire(String? raw) =>
      raw == 'beta' ? ThemeTrack.beta : ThemeTrack.production;
}

/// A catalog row from `GET /api/v1/themes` (THEMES_CONTRACT.md §3/§4).
///
/// Mirrors [MiniApp]'s shape and conventions: locale-keyed name /
/// description maps, an absolute (CDN-rewritten) `icon` / `coverImage`,
/// a `requires` compat block reused verbatim from mini-apps, and an
/// `isInstalled` derived flag merged in by the state layer. The key
/// difference vs a mini-app: there is **no `url`** (themes aren't
/// WebViews) — instead an inline [spec] (a [ThemeSpec]) so a tile can
/// render a palette preview without downloading the bundle.
///
/// [isActive] / [isBuiltIn] are derived fields. `isActive` comes from
/// comparing the row id against `AppSettings.activeThemeId`; `isBuiltIn`
/// marks the bundled defaults (Midnight / Daylight / Neon) that ship in
/// the APK and need no network. The repository emits rows with both
/// false; the state layer stamps them before the UI sees the row.
class ThemeItem {
  const ThemeItem({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.version,
    required this.category,
    required this.spec,
    this.coverImage,
    this.screenshots = const <String>[],
    this.minHostVersion = '0.0.0',
    this.tags = const <String>[],
    this.requires,
    this.bundleUrl = '',
    this.bundleSha256 = '',
    this.track = ThemeTrack.production,
    this.releaseNotes,
    this.isBuiltIn = false,
    this.isActive = false,
  });

  /// Globally-unique, immutable id (`^[a-z0-9][a-z0-9_-]{1,63}$`). The
  /// only thing persisted in `AppSettings.activeThemeId`; everything
  /// else is re-hydrated from the catalog / built-ins on launch.
  final String id;

  /// Locale code → display name. ≥1 entry; [localizedName] falls back
  /// `exact → en → first`.
  final Map<String, String> name;

  /// Same shape as [name]; may be empty.
  final Map<String, String> description;

  /// Absolute tile-icon URL (rendered via `MiniAppRemoteImage`). Empty
  /// for built-in rows that draw a palette swatch instead.
  final String icon;

  /// Optional wide hero banner shown in the gallery / detail.
  final String? coverImage;

  /// Optional pre-apply screenshot gallery (absolute URLs).
  final List<String> screenshots;

  /// Opaque bundle version (semver by convention). Bump busts the CDN
  /// cache, same discipline as mini-apps.
  final String version;

  /// Minimum host version this theme needs. Reserved for a future
  /// host-version gate; not enforced in v1 (a theme is pure tokens and
  /// degrades gracefully).
  final String minHostVersion;

  /// Theme category slug (closed enum, THEMES_CONTRACT.md §1). Kept as
  /// a plain string so the backend can add categories without a client
  /// release.
  final String category;

  /// Optional free-form tags (`^[a-z0-9-]+$`).
  final List<String> tags;

  /// Hard vehicle-compat requirements — reused verbatim from mini-apps
  /// (THEMES_CONTRACT.md §7.3). Null = "runs on any car".
  final MiniAppRequires? requires;

  /// The inline design-token document (THEMES_CONTRACT.md §2). This is
  /// what `AppTheme.fromSpec` consumes when the theme is applied, and
  /// what the tile reads to draw its palette preview.
  final ThemeSpec spec;

  /// HTTPS URL of the versioned bundle tarball. Empty for built-ins
  /// (their assets ship in the APK). Reserved for the wallpaper/font
  /// download path; v1 applies the inline [spec] directly.
  final String bundleUrl;

  /// SHA-256 hex of the bundle tarball. Empty for built-ins.
  final String bundleSha256;

  /// Release track. Production rows default here; beta rows surface a
  /// BETA pill in the gallery.
  final ThemeTrack track;

  /// Short developer release notes — beta-only, nullable.
  final String? releaseNotes;

  /// True for the bundled default themes (no network needed). The
  /// gallery always lists these first so a fresh / offline car still
  /// has a working picker.
  final bool isBuiltIn;

  /// True iff this row's id matches `AppSettings.activeThemeId` (or it's
  /// the built-in default when the setting is empty). Merged in by the
  /// state layer.
  final bool isActive;

  bool get isBeta => track == ThemeTrack.beta;

  static String _pickLocalized(Map<String, String> map, String languageCode) {
    if (map.isEmpty) return '';
    final exact = map[languageCode];
    if (exact != null && exact.isNotEmpty) return exact;
    final english = map['en'];
    if (english != null && english.isNotEmpty) return english;
    return map.values.first;
  }

  String localizedName(String languageCode) =>
      _pickLocalized(name, languageCode);

  String localizedDescription(String languageCode) =>
      _pickLocalized(description, languageCode);

  /// Defensive manual parse — mirrors `ApiMiniAppRepository._miniAppFromJson`.
  /// One malformed row falls back to defaults (and the built-in dark
  /// spec) rather than crashing the whole catalog. `spec` is required by
  /// the contract; a missing / malformed spec degrades to the built-in
  /// dark spec so the row still renders and applies safely.
  factory ThemeItem.fromJson(Map<String, dynamic> json) {
    final localizedName =
        (json['name'] as Map?)?.cast<String, String>() ??
        {'en': (json['id'] as String? ?? '')};
    final localizedDescription =
        (json['description'] as Map?)?.cast<String, String>() ?? const {};
    final specRaw = json['spec'];
    final spec = specRaw is Map<String, dynamic>
        ? ThemeSpec.fromJson(specRaw)
        : (specRaw is Map
              ? ThemeSpec.fromJson(specRaw.cast<String, Object?>())
              : kBuiltInDarkSpec);
    return ThemeItem(
      id: (json['id'] as String?) ?? '',
      name: localizedName,
      description: localizedDescription,
      icon: (json['icon'] as String?) ?? '',
      version: (json['version'] as String?) ?? '1.0.0',
      minHostVersion: (json['minHostVersion'] as String?) ?? '0.0.0',
      category: (json['category'] as String?) ?? 'other',
      tags: _readStringList(json['tags']),
      requires: MiniAppRequires.fromJson(json['requires']),
      spec: spec,
      coverImage: json['coverImage'] as String?,
      screenshots: _readStringList(json['screenshots']),
      bundleUrl: (json['bundleUrl'] as String?) ?? '',
      bundleSha256: (json['bundleSha256'] as String?) ?? '',
      track: ThemeTrack.fromWire(json['track'] as String?),
      releaseNotes: json['releaseNotes'] as String?,
    );
  }

  static List<String> _readStringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// Returns a copy with the derived [isBuiltIn] / [isActive] fields
  /// overwritten. Only the derived fields are mutable here — the rest
  /// of the row is owned by the catalog / built-ins.
  ThemeItem withState({bool? isBuiltIn, bool? isActive}) => ThemeItem(
    id: id,
    name: name,
    description: description,
    icon: icon,
    version: version,
    minHostVersion: minHostVersion,
    category: category,
    tags: tags,
    requires: requires,
    spec: spec,
    coverImage: coverImage,
    screenshots: screenshots,
    bundleUrl: bundleUrl,
    bundleSha256: bundleSha256,
    track: track,
    releaseNotes: releaseNotes,
    isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    isActive: isActive ?? this.isActive,
  );
}
