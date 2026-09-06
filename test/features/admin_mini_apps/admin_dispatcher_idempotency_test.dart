/// Idempotency-key behaviour for the admin dispatcher.
///
/// The SDK sends a uuid on every `_admin.exec` call. The dispatcher
/// uses (app_id, key) to detect retries and return the prior
/// envelope without re-executing — so a mini-app interrupted
/// mid-op (network blip, WebView reload) doesn't double-execute a
/// privileged op on retry.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/consent_repository.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/audit_chain_store.dart';
import 'package:ilink/features/admin_mini_apps/data/db/revocation_list_store.dart';
import 'package:ilink/features/admin_mini_apps/data/db/session_cap_store.dart';
import 'package:ilink/features/admin_mini_apps/data/db/template_catalog_store.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _certHash = 'cert-abc';
const _userId = 'u1';
const _vin = 'WDB1234567';
const _appId = 'diagnostics-pro';

const _session = AdminSession(
  userId: _userId,
  deviceId: _vin,
  appId: _appId,
  certHash: _certHash,
);

/// Counts every executor call so the test can prove a replay does
/// NOT reach the executor.
class _CountingExecutor implements AdminOpExecutor {
  int calls = 0;
  @override
  Future<Map<String, Object?>> run({
    required CommandTemplate template,
    required Map<String, Object?> validatedParams,
    required String renderedShell,
  }) async {
    calls++;
    return {'echo': renderedShell, 'op': template.id, 'callNumber': calls};
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late SessionCapStore caps;
  late AuditChainStore audit;
  late TemplateCatalogStore tmpls;
  late RevocationListStore revs;
  late InMemoryAdminConsentRepository consents;
  late _CountingExecutor executor;
  late AdminMiniAppDispatcher dispatcher;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    caps = SessionCapStore(db);
    audit = AuditChainStore(db);
    tmpls = TemplateCatalogStore(db);
    revs = RevocationListStore(db);
    consents = InMemoryAdminConsentRepository();
    executor = _CountingExecutor();
    dispatcher = AdminMiniAppDispatcher(
      sessionCaps: caps,
      auditChain: audit,
      templates: tmpls,
      revocations: revs,
      consents: consents,
      executor: executor,
    );
    addTearDown(db.close);

    // Tier-1 template — the simplest passing path. Idempotency is
    // independent of tier, so tier-1 keeps the test focused on the
    // dedup branch instead of the cap cascade.
    await tmpls.replaceForCert(
      certHash: _certHash,
      templates: [
        CommandTemplate(
          id: 'diag.tail_logs',
          permissionId: 'cmdExec.read',
          tier: AdminOpTier.tier1,
          requiresStepUp: false,
          category: 'diagnostics',
          shellTemplate: 'logcat -d -t {lines}',
          paramSchema: {
            'lines': const IntParamRule(min: 1, max: 1000, defaultValue: 100),
          },
        ),
      ],
    );
  });

  test(
    'first call with a key executes; second with same key replays',
    () async {
      final r1 = await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 50},
        idempotencyKey: 'idem-1',
        currentSession: _session,
      );
      expect(r1, isA<AdminExecOk>());
      expect(executor.calls, 1);
      final firstCallNum = (r1 as AdminExecOk).data['callNumber'];
      expect(firstCallNum, 1);

      // Same key → must NOT re-execute, must return the prior envelope.
      final r2 = await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 50},
        idempotencyKey: 'idem-1',
        currentSession: _session,
      );
      expect(r2, isA<AdminExecOk>());
      expect(
        executor.calls,
        1,
        reason: 'replay must not invoke executor again',
      );
      // Replay returns the original result — same callNumber proves it.
      expect((r2 as AdminExecOk).data['callNumber'], 1);
    },
  );

  test('different keys execute independently', () async {
    await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 1},
      idempotencyKey: 'idem-A',
      currentSession: _session,
    );
    await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 1},
      idempotencyKey: 'idem-B',
      currentSession: _session,
    );
    expect(executor.calls, 2);
  });

  test('null key disables dedup — every call executes', () async {
    await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 1},
      currentSession: _session,
    );
    await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 1},
      currentSession: _session,
    );
    expect(
      executor.calls,
      2,
      reason: 'no key → no dedup; both calls go through',
    );
  });

  test(
    'empty-string key is treated as no key (not as a literal value)',
    () async {
      await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 1},
        idempotencyKey: '',
        currentSession: _session,
      );
      await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 1},
        idempotencyKey: '',
        currentSession: _session,
      );
      expect(executor.calls, 2);
    },
  );

  test('audit row records the idempotency key', () async {
    await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 1},
      idempotencyKey: 'audit-idem-key',
      currentSession: _session,
    );
    final found = await audit.findByIdempotencyKey(
      appId: _appId,
      idempotencyKey: 'audit-idem-key',
    );
    expect(found, isNotNull);
    expect(found!.idempotencyKey, 'audit-idem-key');
    expect(found.op, 'diag.tail_logs');
  });

  test(
    'same key from a different app does NOT replay — keys are scoped per app',
    () async {
      await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 1},
        idempotencyKey: 'shared-key',
        currentSession: _session,
      );
      expect(executor.calls, 1);

      // Different app, same key. The (app_id, key) tuple is the
      // dedup unit, so this MUST execute independently.
      const otherSession = AdminSession(
        userId: _userId,
        deviceId: _vin,
        appId: 'other-app',
        certHash: _certHash,
      );
      // Seed the catalog for the other cert isn't needed — same cert,
      // different app id. Catalog lookup is by cert_hash only, so the
      // template is reachable.
      await dispatcher.exec(
        templateId: 'diag.tail_logs',
        params: const {'lines': 1},
        idempotencyKey: 'shared-key',
        currentSession: otherSession,
      );
      expect(executor.calls, 2);
    },
  );
}
