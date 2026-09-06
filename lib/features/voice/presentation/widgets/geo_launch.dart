/// Shared "open this point in a map/nav app" launcher.
///
/// ``geo:`` is the canonical Android intent for "open this location in
/// a map app". With multiple nav apps installed (Waze / Petal / Yandex …)
/// Android shows its "Open with" chooser — Google Maps can't render on
/// this GMS-less BYD, so handing off to a working nav app is the whole
/// point. Falls back to a Google Maps web URL when no ``geo:`` handler
/// exists (emulator / future iOS).
///
/// **Coordinate-authoritative form.** For navigating to a *specific*
/// point we use ``geo:lat,lng?q=lat,lng(Label)`` — the ``q`` carries the
/// coordinates with the name only as a parenthesised display label.
/// Earlier we sent ``q=<Name>``, which apps like Waze treat as a text
/// search: they'd re-search the name and land on the wrong place (or
/// nothing). Putting the coordinates in ``q`` makes the pin exact and
/// consistent across every nav app, while the label still shows.
///
/// Single producer for both the ``find_nearby`` card (tap a result)
/// and the ``navigate_to`` display (auto-launch) so the intent format +
/// fallback live in one place.
library;

import 'package:url_launcher/url_launcher.dart';

/// Launch the platform map/nav app at [lat],[lng] labelled [label].
/// Returns true if either the geo: intent or the web fallback opened.
Future<bool> launchGeoIntent({
  required double lat,
  required double lng,
  required String label,
}) async {
  // q=lat,lng(Label): coordinates are authoritative, the name is only a
  // display label — so the destination app pins the exact point instead
  // of text-searching the name.
  final geoUri = Uri.parse(
    'geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label)})',
  );
  try {
    if (await launchUrl(geoUri, mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {
    // fall through to web
  }
  final webUri = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
  );
  try {
    return await launchUrl(webUri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Genuinely no browser + no map app — caller already has text on
    // screen; swallow so a misconfigured emulator doesn't crash.
    return false;
  }
}

/// Open the nav app to a SEARCH near [lat],[lng] — used for "show all on
/// map" when we have many results: ``geo:lat,lng?q=<query>`` makes the
/// map app render every match in the area (we can't draw our own map on
/// GMS-less hardware). Falls back to a Google Maps web search.
Future<bool> launchGeoSearch({
  required double lat,
  required double lng,
  required String query,
}) async {
  final geoUri = Uri.parse('geo:$lat,$lng?q=${Uri.encodeComponent(query)}');
  try {
    if (await launchUrl(geoUri, mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {
    // fall through to web
  }
  final webUri = Uri.parse(
    'https://www.google.com/maps/search/?api=1'
    '&query=${Uri.encodeComponent(query)}',
  );
  try {
    return await launchUrl(webUri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Dial [phone] via the platform dialer (``tel:``). Best-effort.
Future<bool> launchDial(String phone) async {
  final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r"[^0-9+]"), "")}');
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Open [url] in the browser. Best-effort.
Future<bool> launchWeb(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
