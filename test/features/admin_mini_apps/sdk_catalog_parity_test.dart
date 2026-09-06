/// Parity test — proves the Dart `CommandTemplate.toMiniAppJson()`
/// output matches the wire shape the SDK's `CommandTemplate` Zod
/// schema accepts (`packages/admin-sdk/src/types.ts`).
///
/// This test is the contract fence: a future Dart change that adds
/// or renames a field, drops a key, or changes a value type will
/// fail here BEFORE the change ships and the SDK starts rejecting
/// catalog rows at runtime. When the schema evolves, update both
/// sides in the same PR and update this test.
///
/// Crucial security property covered by this test: the rendered
/// shell text (`shellTemplate`) MUST NOT appear in the wire shape.
/// A regression that leaks it would tell a compromised mini-app
/// exactly which native call to abuse if the sandbox ever escaped.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';

void main() {
  group('CommandTemplate.toMiniAppJson — SDK parity', () {
    test('exact key set matches the SDK CommandTemplate schema', () {
      final t = CommandTemplate(
        id: 'pm.disable_user',
        permissionId: 'cmdExec.control',
        tier: AdminOpTier.tier2,
        requiresStepUp: false,
        category: 'package_manager',
        shellTemplate: 'pm disable-user --user {user} "{package}"',
        paramSchema: {
          'user': const EnumParamRule(values: [0, 999]),
          'package': const EnumParamRule(
            values: ['com.byd.trafficmonitor', 'com.byd.autovoice'],
          ),
        },
        description: 'Disable a system app for a user',
      );

      final json = t.toMiniAppJson();

      // Exactly these keys, no others. Any addition is a contract
      // change that needs the SDK side updated in lockstep.
      expect(
        json.keys.toSet(),
        equals({
          'id',
          'permissionId',
          'tier',
          'requiresStepUp',
          'category',
          'description',
          'paramSchema',
        }),
      );

      expect(json['id'], 'pm.disable_user');
      expect(json['permissionId'], 'cmdExec.control');
      expect(json['tier'], 2); // 1 | 2 — not the enum index
      expect(json['requiresStepUp'], false);
      expect(json['category'], 'package_manager');
      expect(json['description'], 'Disable a system app for a user');
    });

    test('tier-1 serializes tier as 1 (not 0)', () {
      final t = CommandTemplate(
        id: 'diag.tail_logs',
        permissionId: 'cmdExec.read',
        tier: AdminOpTier.tier1,
        requiresStepUp: false,
        category: 'diagnostics',
        shellTemplate: 'logcat -d -t {lines}',
        paramSchema: {
          'lines': const IntParamRule(min: 1, max: 1000, defaultValue: 100),
        },
      );
      expect(t.toMiniAppJson()['tier'], 1);
    });

    test('description is omitted when null (not serialized as null)', () {
      final t = CommandTemplate(
        id: 'sys.reboot',
        permissionId: 'cmdExec.control',
        tier: AdminOpTier.tier2,
        requiresStepUp: true,
        category: 'system',
        shellTemplate: 'reboot',
        paramSchema: const {},
      );
      final json = t.toMiniAppJson();
      expect(json.containsKey('description'), isFalse);
    });

    test('shellTemplate is NEVER in the wire shape (security-critical)', () {
      final t = CommandTemplate(
        id: 'pm.install',
        permissionId: 'cmdExec.control',
        tier: AdminOpTier.tier2,
        requiresStepUp: true,
        category: 'package_manager',
        shellTemplate: 'pm install --user {user} {apk_path}',
        paramSchema: {
          'user': const EnumParamRule(values: [0, 999]),
          'apk_path': RegexParamRule(pattern: r'^/data/local/tmp/.+\.apk$'),
        },
      );
      final json = t.toMiniAppJson();
      // Walk the entire serialized blob — the shell text must not
      // appear under any key, no matter how deep.
      expect(json.containsKey('shellTemplate'), isFalse);
      expect(json.containsKey('shell_template'), isFalse);
      expect(json.toString().contains('pm install'), isFalse);
    });
  });

  group('ParamRule.toMiniAppJson — SDK parity', () {
    test('IntParamRule serializes type=int with optional bounds', () {
      // With all fields.
      const full = IntParamRule(min: 1, max: 1000, defaultValue: 100);
      expect(full.toMiniAppJson(), {
        'type': 'int',
        'min': 1,
        'max': 1000,
        'default': 100,
      });

      // Without optional fields — they must be omitted, not null.
      const empty = IntParamRule();
      expect(empty.toMiniAppJson(), {'type': 'int'});
    });

    test('EnumParamRule serializes type=enum with values', () {
      const r = EnumParamRule(values: [0, 999]);
      expect(r.toMiniAppJson(), {
        'type': 'enum',
        'values': [0, 999],
      });
    });

    test('RegexParamRule serializes type=regex with pattern', () {
      final r = RegexParamRule(pattern: r'^/data/local/tmp/.+\.apk$');
      expect(r.toMiniAppJson(), {
        'type': 'regex',
        'pattern': r'^/data/local/tmp/.+\.apk$',
      });
    });

    test('round-trip: toMiniAppJson → ParamRule.fromJson → toMiniAppJson', () {
      // The same JSON shape must reconstruct an equivalent rule —
      // proves the wire format is the single source of truth.
      const original = IntParamRule(min: 0, max: 10);
      final roundTripped = ParamRule.fromJson(original.toMiniAppJson());
      expect(roundTripped.toMiniAppJson(), original.toMiniAppJson());
    });
  });
}
