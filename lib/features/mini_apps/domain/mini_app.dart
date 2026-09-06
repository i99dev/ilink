import 'mini_app_compat.dart';
import 'mini_app_track.dart';

/// A third-party (or first-party) mini-app listed in the in-app catalog.
///
/// The host renders these as tiles in the Store / "My Apps" surfaces and
/// opens [url] inside a sandboxed WebView when the user launches one.
/// Names and descriptions are locale-keyed maps rather than a single
/// `name` field so the catalog can ship the Arabic + English strings
/// together — the host resolves the right one per active locale via
/// [localizedName] / [localizedDescription] without a second fetch.
///
/// [safeWhileDriving] is the single switch that gates runtime display
/// while the car is moving — default `false` is intentionally
/// conservative so a new catalog entry never accidentally opts in to
/// being shown at speed.
///
/// [isInstalled] and [installedAt] are derived fields — they come from
/// the local [MiniAppInstallStorage], not from the remote catalog.
/// The repository emits catalog rows with `isInstalled: false` and the
/// state layer merges the storage map onto each row before exposing it
/// to the UI.
class MiniApp {
  const MiniApp({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.url,
    required this.version,
    required this.minHostVersion,
    required this.category,
    required this.bundleUrl,
    required this.bundleSha256,
    this.safeWhileDriving = false,
    this.privileged = false,
    this.isInstalled = false,
    this.installedAt,
    this.certHash,
    this.track = MiniAppTrack.production,
    // NOTE: copyWith cannot explicitly set releaseNotes to null — the
    // standard Dart copyWith pitfall: `copyWith(releaseNotes: null)` is
    // indistinguishable from `copyWith()`. Nothing in the current code
    // base needs to clear release notes via copyWith (the field is set
    // once on catalog parse and otherwise read-only), so a sentinel is
    // overkill. If a future flow needs to clear it, construct a new
    // MiniApp directly.
    this.releaseNotes,
    // Cover banner shown above the description in the details modal.
    // Wide-format hero image; falls back to nothing if absent. Backend
    // catalog ships `coverImage`; legacy rows pass null and the UI
    // collapses the banner section.
    this.coverImage,
    // Up to N hero/screenshot URLs the user previews before install.
    // Order is publisher-chosen (manifest order). Empty list = no
    // gallery shown — same fallback as `coverImage`.
    this.screenshots = const <String>[],
    // Hard compatibility requirements from the catalog row's
    // `requires` block. Null = "runs on any car" (the common case).
    // Evaluated by `evaluateCompatibility()` at launch — defense in
    // depth behind the backend catalog filter.
    this.requires,
    // Declared external-egress origins from the manifest `network` field.
    // Already canonical (the repository normalizes + dedupes at parse time).
    this.network = const <String>[],
  });

  /// Stable, URL-safe identifier. The only thing stored in local
  /// install state — everything else about the app is re-hydrated
  /// from the catalog on launch.
  final String id;

  /// Locale code (`ar`, `en`, …) → display name. Must contain at least
  /// one entry; [localizedName] falls back through `en` → first-entry.
  final Map<String, String> name;

  /// Same shape as [name]. May be empty when the catalog row doesn't
  /// carry copy — the UI degrades to showing just the name.
  final Map<String, String> description;

  /// Absolute URL to the tile icon. Rendered via
  /// `mini_app_remote_image.dart` which sniffs SVG vs raster from
  /// either the URL extension or the response Content-Type — needed
  /// because Android's native ImageDecoder rejects SVG and emits a
  /// "Failed to create image decoder" error, leaving CDN SVG icons
  /// blank.
  final String icon;

  /// Wide hero banner shown above the description in the details
  /// modal. Optional — null when the publisher didn't supply one.
  final String? coverImage;

  /// Pre-install screenshot gallery. Each element is an absolute
  /// HTTPS URL; ordering is publisher-defined. Rendered as a
  /// horizontally-scrolling strip in the details modal.
  final List<String> screenshots;

  /// Absolute HTTPS URL the WebView opens. Origin is allow-listed
  /// host-side — a catalog row pointing off the approved CDN is
  /// rejected at launch, not at fetch, so a compromised catalog
  /// still can't escape the sandbox.
  final String url;

  /// Semantic version of the mini-app bundle (not the host). Used for
  /// cache-busting when the backend bumps it; a string so we don't
  /// commit to a specific parser.
  final String version;

  /// Minimum host app version this mini-app needs. The launcher
  /// compares against `package_info_plus` and shows an "update your
  /// app" card instead of opening an unsupported bridge.
  final String minHostVersion;

  /// Hard vehicle-compat requirements (`requires` block) from the
  /// catalog row. Null when the app declares none ("runs anywhere").
  /// Evaluated by `evaluateCompatibility()` on launch — host-side
  /// defense in depth behind the backend catalog filter, mirroring
  /// the SDK/backend so the answer can't drift.
  final MiniAppRequires? requires;

  /// Free-form grouping key ("services", "info", "entertainment", …).
  /// The Store screen groups tiles by this. Kept as a plain String
  /// rather than an enum so the backend can add categories without a
  /// client release.
  final String category;

  /// Whether the host is allowed to render this app while the car is
  /// moving. Default `false` — catalog authors must explicitly opt in.
  final bool safeWhileDriving;

  /// HTTPS URL of the versioned bundle tarball
  /// (`bundles/<id>/<version>/bundle.tar.gz`). The host downloads
  /// this on Install, hash-verifies the bytes against
  /// [bundleSha256], extracts to app-private storage, and launches
  /// the WebView from `file://`. Stays in the model so updates
  /// (catalog version > installed version) can compare URLs +
  /// re-download as needed.
  final String bundleUrl;

  /// SHA-256 hex digest of the bundle tarball. The host fails the
  /// install if a fresh download doesn't hash-match this — closes
  /// the "compromised CDN swaps bytes" attack vector.
  final String bundleSha256;

  /// Whether this app is a *privileged* mini-app (uses `_admin.exec`)
  /// and so requires the cert + session-cap install pipeline. Default
  /// `false` — regular mini-apps install via the CDN-bytes-and-hash
  /// path. The runtime gate (no privileged ops without a verified
  /// cert) is enforced inside the Flutter dispatcher: even if this
  /// flag is wrong, an app without a stored [certHash] fails at the
  /// dispatcher's template-lookup step. The flag exists so the
  /// install flow can decide *up front* whether to fetch the cert +
  /// cap, not to gate runtime behaviour.
  final bool privileged;

  /// True iff the id is present in [MiniAppInstallStorage]. Merged in
  /// by the catalog controller before the UI sees the row.
  final bool isInstalled;

  /// When the user installed this mini-app. Null while the row is in
  /// its pre-merge state (straight from the repository) or when the
  /// user hasn't installed it.
  final DateTime? installedAt;

  /// SHA-256 hex of the developer cert this bundle is signed under.
  /// Populated for privileged mini-apps after the install flow's
  /// cert-verify step; null for non-privileged apps and for any row
  /// that hasn't been installed yet. Consumed by `_handleAdminExec`
  /// inside `MiniAppViewer` to build the dispatcher's `AdminSession`.
  final String? certHash;

  /// Release track for this catalog row. Defaults to
  /// [MiniAppTrack.production] (also used when the backend omits the
  /// field). The Store tab renders a BETA pill when this is
  /// [MiniAppTrack.beta], and [openMiniApp] intercepts the first
  /// launch to show the consent sheet defined in
  /// `beta_consent_sheet.dart`.
  final MiniAppTrack track;

  final String? releaseNotes;

  /// Declared external-egress allow-list: canonical HTTPS origins
  /// (`https://host[:port]`) this app may reach with a browser `fetch()`,
  /// from the manifest `network` field. The viewer turns this (∪ the global
  /// bundle origin) into the request-interceptor gate ([isAllowedMiniAppRequest])
  /// and the injected CSP ([buildMiniAppCsp]). Empty = no third-party egress
  /// (the app can still load its own bundle). Egress is unauthenticated.
  final List<String> network;

  /// Convenience getter — avoids sprinkling `== MiniAppTrack.beta`
  /// comparisons across presentation code.
  bool get isBeta => track == MiniAppTrack.beta;

  /// Picks the best-matching localized string from [map], preferring
  /// an exact locale hit, then English, then the first value. Used
  /// for both [name] and [description] so the fallback rule stays
  /// identical — callers only pass the map they care about.
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

  /// Returns a copy with the install-state fields overwritten. Used by
  /// the catalog controller to stamp storage data onto each fetched
  /// row. Only the derived fields are exposed here — the rest of the
  /// row is owned by the remote catalog and shouldn't be mutated
  /// client-side.
  ///
  /// [certHash] is also a derived field for privileged mini-apps; pass
  /// the value persisted by the install pipeline so the viewer can
  /// build a real `AdminSession` instead of the empty-string fallback.
  MiniApp withInstallState({
    required bool isInstalled,
    DateTime? installedAt,
    String? certHash,
  }) {
    return MiniApp(
      id: id,
      name: name,
      description: description,
      icon: icon,
      url: url,
      version: version,
      minHostVersion: minHostVersion,
      category: category,
      bundleUrl: bundleUrl,
      bundleSha256: bundleSha256,
      safeWhileDriving: safeWhileDriving,
      privileged: privileged,
      isInstalled: isInstalled,
      installedAt: installedAt,
      certHash: certHash,
      track: track,
      releaseNotes: releaseNotes,
      coverImage: coverImage,
      screenshots: screenshots,
      // Preserve compat requirements + declared egress across the stamp —
      // both are owned by the catalog row, not derived install state, so
      // dropping them here would silently weaken launch-gate + CSP after a
      // storage merge.
      requires: requires,
      network: network,
    );
  }
}
