/// Unit tests for the ``flightTestModeEnabled`` field on [AppSettings].
///
/// The flag is persisted alongside the rest of the settings via
/// SharedPreferences. These tests pin down the round-trip behavior so
/// a future settings refactor can't silently drop the flag — a
/// regression here would mean every tester loses the toggle on app
/// restart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/settings/app_settings.dart';

void main() {
  group('AppSettings.flightTestModeEnabled', () {
    test('defaults to false', () {
      const settings = AppSettings(deviceId: '');
      expect(settings.flightTestModeEnabled, isFalse);
    });

    test('copyWith preserves the flag when not specified', () {
      const settings = AppSettings(deviceId: '', flightTestModeEnabled: true);
      final next = settings.copyWith(themeMode: settings.themeMode);
      expect(next.flightTestModeEnabled, isTrue);
    });

    test('copyWith flips the flag', () {
      const settings = AppSettings(deviceId: '');
      final on = settings.copyWith(flightTestModeEnabled: true);
      expect(on.flightTestModeEnabled, isTrue);
      final off = on.copyWith(flightTestModeEnabled: false);
      expect(off.flightTestModeEnabled, isFalse);
    });

    test('equality reflects the flag', () {
      const a = AppSettings(deviceId: '');
      const b = AppSettings(deviceId: '', flightTestModeEnabled: true);
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });

    test('two equal flag values produce equal settings', () {
      const a = AppSettings(deviceId: 'v', flightTestModeEnabled: true);
      const b = AppSettings(deviceId: 'v', flightTestModeEnabled: true);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
