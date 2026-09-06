import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_deep_link.dart';

void main() {
  test('shortcut uses a local custom scheme without domain verification', () {
    expect(
      buildMiniAppDeepLink('fuel_prices'),
      'car-ilink://mini-app/fuel_prices',
    );
  });
  test('builder escapes the ID and parser round-trips it', () {
    for (final id in ['fuel_prices', 'space in id', 'a1-b2_c3']) {
      expect(parseMiniAppDeepLink(Uri.parse(buildMiniAppDeepLink(id))), id);
    }
    expect(buildMiniAppDeepLink('space in id'), contains('space%20in%20id'));
  });
  test('query does not alter the local mini-app identity', () {
    expect(
      parseMiniAppDeepLink(Uri.parse('car-ilink://mini-app/weather?src=pin')),
      'weather',
    );
  });
  test('old package-targeted shortcuts still resolve locally', () {
    expect(
      parseMiniAppDeepLink(Uri.parse('https://app.i99dash.com/m/fuel_prices')),
      'fuel_prices',
    );
  });
  test('rejects unrelated remote links and malformed local links', () {
    for (final value in [
      'https://app.i99dash.com/m/fuel_prices/extra',
      'https://app.i99dash.com/m/',
      'http://app.i99dash.com/m/fuel_prices',
      'https://example.com/m/fuel_prices',
      'ilink://mini-app/fuel_prices',
      'car-ilink://other/fuel_prices',
      'car-ilink://mini-app/',
      'car-ilink://mini-app/foo/bar',
    ]) {
      expect(parseMiniAppDeepLink(Uri.parse(value)), isNull, reason: value);
    }
  });
}
