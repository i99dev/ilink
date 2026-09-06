import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/platform/launcher/launcher_privilege_status.dart';

void main() {
  group('LauncherPrivilegeStatus.fromMap', () {
    test('default-constructed status has every field false', () {
      const s = LauncherPrivilegeStatus();
      expect(s.writeSecureSettings, isFalse);
      expect(s.readLogs, isFalse);
      expect(s.packageUsageStats, isFalse);
      expect(s.systemAlertWindow, isFalse);
      expect(s.ignoreBatteryOptimizations, isFalse);
      expect(s.isDefaultHome, isFalse);
      expect(s.remoteControlA11yEnabled, isFalse);
      expect(s.watchdogA11yEnabled, isFalse);
      expect(s.homeAliasEnabled, isFalse);
      expect(s.grantedCount, 0);
    });

    test('parses every key from the channel-shaped Map', () {
      final raw = <String, Object?>{
        'writeSecureSettings': true,
        'readLogs': true,
        'packageUsageStats': true,
        'systemAlertWindow': true,
        'ignoreBatteryOptimizations': true,
        'isDefaultHome': true,
        'remoteControlA11yEnabled': true,
        'watchdogA11yEnabled': true,
        'homeAliasEnabled': true,
      };
      final s = LauncherPrivilegeStatus.fromMap(raw);
      expect(s.grantedCount, LauncherPrivilegeStatus.totalCount);
      expect(s.isDefaultHome, isTrue);
      expect(s.homeAliasEnabled, isTrue);
    });

    test('treats missing keys as false (forward-compat with older HUs)', () {
      final raw = <String, Object?>{'writeSecureSettings': true};
      final s = LauncherPrivilegeStatus.fromMap(raw);
      expect(s.writeSecureSettings, isTrue);
      expect(s.readLogs, isFalse);
      expect(s.grantedCount, 1);
    });

    test('treats non-boolean truthy values as false (strict equality)', () {
      // Defensive: Kotlin side returns real bools, but if a future
      // change accidentally returns 1/0 or "true"/"false", the
      // status grid should fail closed (show as not-granted) rather
      // than silently accept the wrong type.
      final raw = <String, Object?>{
        'writeSecureSettings': 1,
        'readLogs': 'true',
        'isDefaultHome': true,
      };
      final s = LauncherPrivilegeStatus.fromMap(raw);
      expect(s.writeSecureSettings, isFalse);
      expect(s.readLogs, isFalse);
      expect(s.isDefaultHome, isTrue);
      expect(s.grantedCount, 1);
    });
  });

  group('LauncherPrivilegeStatus.grantedCount', () {
    test('counts only true fields', () {
      const s = LauncherPrivilegeStatus(
        writeSecureSettings: true,
        readLogs: true,
        homeAliasEnabled: true,
      );
      expect(s.grantedCount, 3);
    });
  });
}
