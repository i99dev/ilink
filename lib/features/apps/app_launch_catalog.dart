/// Declarative catalog of apps the Voice AI can launch on the car, plus the
/// pure `am start` argv builders the dispatcher uses.
///
/// Scaling axis: a new app is ONE [AppLaunchSpec] entry — no dispatcher
/// changes. Each spec carries the package + optional deep-link TEMPLATES for
/// the two query-bearing actions (search/play, navigate). `{q}` in a template
/// is replaced by the URL-encoded query at dispatch time.
///
/// On-car tuning caveat (same as the wake-phrase catalog): exact deep-link
/// schemes vary by app version / market, and Google apps may be absent on
/// China-market BYD units. Launches degrade gracefully — an unresolved app or
/// a failed `am start` returns a clear error the assistant speaks back
/// ("YouTube isn't installed"), never a silent no-op.
library;

/// One launchable app. [package] is the Android package id; [aliases] are the
/// spoken names the resolver matches (lowercased). [searchUri] / [navUri] are
/// VIEW deep-link templates with a `{q}` placeholder — null means the app
/// doesn't support that action (the dispatcher falls back to a plain launch).
class AppLaunchSpec {
  const AppLaunchSpec({
    required this.key,
    required this.displayName,
    required this.package,
    this.aliases = const [],
    this.searchUri,
    this.navUri,
  });

  final String key;
  final String displayName;
  final String package;
  final List<String> aliases;
  final String? searchUri;
  final String? navUri;
}

/// The known apps. DRAFT deep links — easy to tune per car here in one place.
const List<AppLaunchSpec> appLaunchCatalog = [
  AppLaunchSpec(
    key: 'youtube',
    displayName: 'YouTube',
    package: 'com.google.android.youtube',
    aliases: ['youtube', 'you tube', 'yt'],
    // The app claims youtube.com results URLs; forcing the package (trailing
    // arg in viewIntentArgv) keeps it out of a browser.
    searchUri: 'https://www.youtube.com/results?search_query={q}',
  ),
  AppLaunchSpec(
    key: 'spotify',
    displayName: 'Spotify',
    package: 'com.spotify.music',
    aliases: ['spotify'],
    // Spotify's own scheme — opens search results in-app.
    searchUri: 'spotify:search:{q}',
  ),
  AppLaunchSpec(
    key: 'youtube_music',
    displayName: 'YouTube Music',
    package: 'com.google.android.apps.youtube.music',
    aliases: ['youtube music', 'yt music'],
    searchUri: 'https://music.youtube.com/search?q={q}',
  ),
  AppLaunchSpec(
    key: 'maps',
    displayName: 'Google Maps',
    package: 'com.google.android.apps.maps',
    aliases: ['maps', 'google maps', 'map', 'navigation', 'navigate'],
    // `google.navigation:` starts turn-by-turn directly; `geo:` just searches.
    navUri: 'google.navigation:q={q}',
    searchUri: 'geo:0,0?q={q}',
  ),
  AppLaunchSpec(
    key: 'waze',
    displayName: 'Waze',
    package: 'com.waze',
    aliases: ['waze'],
    navUri: 'https://waze.com/ul?q={q}&navigate=yes',
    searchUri: 'https://waze.com/ul?q={q}',
  ),
  AppLaunchSpec(
    key: 'yandex_maps',
    displayName: 'Yandex Maps',
    package: 'ru.yandex.yandexmaps',
    // "yandex" alone defaults here (Maps) over Navigator; Cyrillic aliases
    // for ru-locale speech.
    aliases: [
      'yandex maps',
      'yandex map',
      'yandex',
      'яндекс карты',
      'яндекс',
      'карты',
    ],
    navUri: 'yandexmaps://maps.yandex.ru/?rtext=~{q}&rtt=auto',
    searchUri: 'yandexmaps://maps.yandex.ru/?text={q}',
  ),
  AppLaunchSpec(
    key: 'yandex_navi',
    displayName: 'Yandex Navigator',
    package: 'ru.yandex.yandexnavi',
    aliases: [
      'yandex navigator',
      'yandex navi',
      'навигатор',
      'яндекс навигатор',
    ],
    // Navigator's text-search entry; the driver picks the result to start
    // turn-by-turn (build_route_on_map needs coords we don't have here).
    navUri: 'yandexnavi://map_search?text={q}',
    searchUri: 'yandexnavi://map_search?text={q}',
  ),
];

/// Resolve a spoken app name to a catalog spec, or null if unknown. Matches
/// (case-insensitively, whitespace-normalized) the key, any alias, the display
/// name, or — as a loose last resort — a containment either way so "open the
/// youtube app" still hits "youtube". Pure + table-driven so it's unit-tested.
AppLaunchSpec? resolveAppSpec(String name) {
  final n = _norm(name);
  if (n.isEmpty) return null;
  for (final spec in appLaunchCatalog) {
    if (spec.key == n ||
        _norm(spec.displayName) == n ||
        spec.aliases.any((a) => _norm(a) == n)) {
      return spec;
    }
  }
  // Loose pass — spoken name contains an alias or vice-versa.
  for (final spec in appLaunchCatalog) {
    final candidates = [spec.key, spec.displayName, ...spec.aliases].map(_norm);
    if (candidates.any(
      (c) => c.isNotEmpty && (n.contains(c) || c.contains(n)),
    )) {
      return spec;
    }
  }
  return null;
}

/// Best-effort match of a spoken app name to an installed package id, used as
/// the generic-launch fallback when the name isn't in [appLaunchCatalog].
/// Compares the de-spaced name against each package's last dotted segment and
/// the whole id. Prefers an exact segment hit, then the shortest containing
/// id (the base app over a sub-package). Pure — [packages] is the parsed
/// `pm list packages` output. Returns null when nothing plausibly matches.
String? matchPackageByName(List<String> packages, String name) {
  final token = _norm(name).replaceAll(' ', '');
  if (token.isEmpty) return null;
  String? exact;
  String? contains;
  for (final pkg in packages) {
    final segment = pkg.split('.').last.toLowerCase();
    if (segment == token) {
      exact ??= pkg;
      continue;
    }
    if (pkg.toLowerCase().contains(token) || segment.contains(token)) {
      if (contains == null || pkg.length < contains.length) contains = pkg;
    }
  }
  return exact ?? contains;
}

/// argv for an implicit VIEW intent on [uri]. When [package] is given it's
/// appended as the trailing intent token so the launch is constrained to that
/// app (keeps an http(s) link out of a browser); an absent app then fails the
/// `am start` cleanly rather than opening the wrong thing.
List<String> viewIntentArgv(String uri, {String? package}) => [
  'am',
  'start',
  '-a',
  'android.intent.action.VIEW',
  '-d',
  uri,
  if (package != null && package.isNotEmpty) package,
];

/// argv to launch [package]'s main LAUNCHER activity without knowing its
/// component name. `monkey` is the portable "just open this app" primitive.
List<String> launcherArgv(String package) => [
  'monkey',
  '-p',
  package,
  '-c',
  'android.intent.category.LAUNCHER',
  '1',
];

/// Fill a deep-link template's `{q}` with the URL-encoded query.
String fillUri(String template, String query) =>
    template.replaceAll('{q}', Uri.encodeComponent(query.trim()));

String _norm(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
