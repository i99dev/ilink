/// Tests for the template engine (Dart side).
///
/// Mirrors ``backend-ilink/tests/admin_perms/test_templates.py`` —
/// every rule kind has a positive + negative test, and rendering is
/// asserted byte-for-byte against the same fixture as the backend
/// to prove the two engines agree.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';

CommandTemplate _tPmDisable() => CommandTemplate(
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
);

CommandTemplate _tDiagTail() => CommandTemplate(
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

CommandTemplate _tInstall() => CommandTemplate(
  id: 'pm.install',
  permissionId: 'cmdExec.control',
  tier: AdminOpTier.tier2,
  requiresStepUp: true,
  category: 'package_manager',
  shellTemplate: 'install --user {user} "{apk_path}"',
  paramSchema: {
    'user': const EnumParamRule(values: [0, 999]),
    'apk_path': RegexParamRule(
      pattern: r'^/data/local/tmp/[A-Za-z0-9._-]+\.apk$',
    ),
  },
);

void main() {
  group('TemplateRegistry', () {
    test('lookup returns templates by id', () {
      final r = TemplateRegistry.fromList([_tPmDisable(), _tDiagTail()]);
      expect(r.lookup('diag.tail_logs')?.id, 'diag.tail_logs');
      expect(r.lookup('pm.disable_user')?.tier, AdminOpTier.tier2);
    });

    test('lookup returns null for unknown ids', () {
      final r = TemplateRegistry.fromList([_tDiagTail()]);
      expect(r.lookup('rm_-rf'), isNull);
    });

    test('all() iterates every registered template', () {
      final r = TemplateRegistry.fromList([_tPmDisable(), _tDiagTail()]);
      expect(r.size, 2);
      expect(r.all().map((t) => t.id).toList(), [
        'pm.disable_user',
        'diag.tail_logs',
      ]);
    });

    test('fromJson round-trips a server-shaped catalog row', () {
      final t = CommandTemplate.fromJson({
        'id': 'pm.disable_user',
        'permissionId': 'cmdExec.control',
        'tier': 2,
        'requiresStepUp': false,
        'category': 'package_manager',
        'shellTemplate': 'pm disable-user --user {user} "{package}"',
        'paramSchema': {
          'user': {
            'type': 'enum',
            'values': [0, 999],
          },
          'package': {
            'type': 'enum',
            'values': ['com.byd.trafficmonitor'],
          },
        },
      });
      expect(t.id, 'pm.disable_user');
      expect(t.tier, AdminOpTier.tier2);
      expect(t.paramSchema.length, 2);
      expect(t.paramSchema['user'], isA<EnumParamRule>());
    });
  });

  group('validateParams — enum', () {
    test('accepts allowed value', () {
      final out = validateParams(_tPmDisable(), {
        'user': 0,
        'package': 'com.byd.autovoice',
      });
      expect(out, {'user': 0, 'package': 'com.byd.autovoice'});
    });

    test('rejects disallowed package', () {
      expect(
        () => validateParams(_tPmDisable(), {
          'user': 0,
          'package': 'com.evil.malware',
        }),
        throwsA(
          isA<TemplateValidationError>().having(
            (e) => e.slot,
            'slot',
            'package',
          ),
        ),
      );
    });

    test('rejects disallowed user id (security boundary)', () {
      expect(
        () => validateParams(_tPmDisable(), {
          'user': 42,
          'package': 'com.byd.autovoice',
        }),
        throwsA(
          isA<TemplateValidationError>().having((e) => e.slot, 'slot', 'user'),
        ),
      );
    });
  });

  group('validateParams — int', () {
    test('accepts in range', () {
      expect(validateParams(_tDiagTail(), {'lines': 50}), {'lines': 50});
    });

    test('default filled when missing', () {
      expect(validateParams(_tDiagTail(), {}), {'lines': 100});
    });

    test('rejects below min', () {
      expect(
        () => validateParams(_tDiagTail(), {'lines': 0}),
        throwsA(isA<TemplateValidationError>()),
      );
    });

    test('rejects above max', () {
      expect(
        () => validateParams(_tDiagTail(), {'lines': 100000}),
        throwsA(isA<TemplateValidationError>()),
      );
    });

    test('rejects bool', () {
      expect(
        () => validateParams(_tDiagTail(), {'lines': true}),
        throwsA(isA<TemplateValidationError>()),
      );
    });
  });

  group('validateParams — regex', () {
    test('accepts matching apk path', () {
      final out = validateParams(_tInstall(), {
        'user': 0,
        'apk_path': '/data/local/tmp/diagnostic-pro-1.0.apk',
      });
      expect(out['apk_path'], '/data/local/tmp/diagnostic-pro-1.0.apk');
    });

    test('rejects path traversal', () {
      expect(
        () => validateParams(_tInstall(), {
          'user': 0,
          'apk_path': '/data/local/tmp/../../system/bin/sh',
        }),
        throwsA(
          isA<TemplateValidationError>().having(
            (e) => e.slot,
            'slot',
            'apk_path',
          ),
        ),
      );
    });

    test('rejects non-apk file', () {
      expect(
        () => validateParams(_tInstall(), {
          'user': 0,
          'apk_path': '/data/local/tmp/innocent.txt',
        }),
        throwsA(isA<TemplateValidationError>()),
      );
    });
  });

  group('validateParams — strict mode', () {
    test('unknown slot rejected', () {
      expect(
        () => validateParams(_tPmDisable(), {
          'user': 0,
          'package': 'com.byd.autovoice',
          'force': true,
        }),
        throwsA(isA<TemplateValidationError>()),
      );
    });

    test('missing required slot rejected', () {
      expect(
        () => validateParams(_tPmDisable(), {'user': 0}),
        throwsA(isA<TemplateValidationError>()),
      );
    });
  });

  group('renderCommand', () {
    test('substitutes string and int slots', () {
      final t = _tPmDisable();
      final v = validateParams(t, {
        'user': 0,
        'package': 'com.byd.trafficmonitor',
      });
      expect(
        renderCommand(t, v),
        'pm disable-user --user 0 "com.byd.trafficmonitor"',
      );
    });

    test('matches the backend output for the BYD disable-user op', () {
      // Same fixture as the Python test
      // ``test_byd_disable_chinese_voice_renders``. Byte-equality
      // here = the two engines agree.
      final t = _tPmDisable();
      final v = validateParams(t, {'user': 0, 'package': 'com.byd.autovoice'});
      expect(
        renderCommand(t, v),
        'pm disable-user --user 0 "com.byd.autovoice"',
      );
    });

    test('raises when a slot in the template is missing from params', () {
      final bad = CommandTemplate(
        id: 'bad',
        permissionId: 'cmdExec.read',
        tier: AdminOpTier.tier1,
        requiresStepUp: false,
        category: 'diagnostics',
        shellTemplate: 'echo {a} {b}',
        paramSchema: {
          'a': const EnumParamRule(values: ['x']),
        },
      );
      final v = validateParams(bad, {'a': 'x'});
      expect(() => renderCommand(bad, v), throwsA(isA<TemplateRenderError>()));
    });
  });
}
