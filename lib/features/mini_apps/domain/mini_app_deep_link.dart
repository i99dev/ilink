/// Local mini-app shortcut URI builder and parser. No hosted domain required.
library;

const String kMiniAppCustomScheme = 'car-ilink';
const String kMiniAppCustomSchemeHost = 'mini-app';

/// Android pinned shortcuts target this app explicitly and use this local URI.
String buildMiniAppDeepLink(String id) => Uri(
  scheme: kMiniAppCustomScheme,
  host: kMiniAppCustomSchemeHost,
  pathSegments: [id],
).toString();

/// Matches a single nonempty mini-app ID in the local custom scheme.
String? parseMiniAppDeepLink(Uri uri) {
  // Existing pinned shortcuts use this URI with an explicit app package.
  // It is accepted locally only; new shortcuts never emit hosted links.
  if (uri.scheme == 'https' &&
      uri.host == 'app.i99dash.com' &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments[0] == 'm') {
    final id = uri.pathSegments[1];
    return id.isEmpty ? null : id;
  }
  if (uri.scheme == kMiniAppCustomScheme &&
      uri.host == kMiniAppCustomSchemeHost &&
      uri.pathSegments.length == 1) {
    final id = uri.pathSegments[0];
    return id.isEmpty ? null : id;
  }
  return null;
}
