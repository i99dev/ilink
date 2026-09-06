/// Tests for AdminMiniAppDispatcher — the single chokepoint for
/// every privileged mini-app op. Covers the gate cascade:
/// template lookup → consent → step-up → revocation freshness →
/// cert revoked → cap present + valid + bound + covers op.
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

void main() {
  setUpAll(sqfliteFfiInit);

  late SessionCapStore caps;
  late AuditChainStore audit;
  late TemplateCatalogStore tmpls;
  late RevocationListStore revs;
  late InMemoryAdminConsentRepository consents;
  late AdminMiniAppDispatcher dispatcher;
  late Database db;

  setUp(() async {
    db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    caps = SessionCapStore(db);
    audit = AuditChainStore(db);
    tmpls = TemplateCatalogStore(db);
    revs = RevocationListStore(db);
    consents = InMemoryAdminConsentRepository();
    dispatcher = AdminMiniAppDispatcher(
      sessionCaps: caps,
      auditChain: audit,
      templates: tmpls,
      revocations: revs,
      consents: consents,
      executor: const EchoAdminOpExecutor(),
    );
    addTearDown(db.close);
  });

  // ── Helpers ───────────────────────────────────────────────────

  CommandTemplate tier1Template() => CommandTemplate(
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

  CommandTemplate tier2Template({bool requiresStepUp = false}) =>
      CommandTemplate(
        id: requiresStepUp ? 'sys.reboot' : 'pm.disable_user',
        permissionId: 'cmdExec.control',
        tier: AdminOpTier.tier2,
        requiresStepUp: requiresStepUp,
        category: requiresStepUp ? 'system' : 'package_manager',
        shellTemplate: requiresStepUp
            ? 'reboot'
            : 'pm disable-user --user {user} "{package}"',
        paramSchema: requiresStepUp
            ? const {}
            : {
                'user': const EnumParamRule(values: [0, 999]),
                'package': const EnumParamRule(
                  values: ['com.byd.trafficmonitor', 'com.byd.autovoice'],
                ),
              },
      );

  Future<void> seedTier1() async {
    await tmpls.replaceForCert(
      certHash: _certHash,
      templates: [tier1Template()],
    );
  }

  Future<void> seedTier2({bool requiresStepUp = false}) async {
    await tmpls.replaceForCert(
      certHash: _certHash,
      templates: [tier2Template(requiresStepUp: requiresStepUp)],
    );
  }

  Future<void> seedFreshRevocationList() async {
    await revs.setMeta(
      lastPulledAt: DateTime.now().toUtc(),
      lastRevokedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> seedActiveCap({Set<String>? opsAllowed}) async {
    await caps.upsert(
      StoredSessionCap(
        userId: _userId,
        deviceId: _vin,
        appId: _appId,
        certHash: _certHash,
        envelope: 'opaque',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
        opsAllowed: opsAllowed ?? {'pm.disable_user'},
        stepUpOps: const {'sys.reboot'},
        renewBeforeSec: 86_400,
        fetchedAt: DateTime.now().toUtc(),
      ),
    );
  }

  // ── Template lookup ───────────────────────────────────────────

  test('unknown template id → unknown_template', () async {
    final r = await dispatcher.exec(
      templateId: 'nonexistent.op',
      currentSession: _session,
    );
    expect(r, isA<AdminExecError>());
    expect((r as AdminExecError).code, DispatchErrorCode.unknownTemplate);
  });

  // ── Tier-1 happy path ─────────────────────────────────────────

  test('tier-1 op runs without cap / consent / revocation gates', () async {
    await seedTier1();
    final r = await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': 50},
      currentSession: _session,
    );
    expect(r, isA<AdminExecOk>());
    final ok = r as AdminExecOk;
    expect(ok.data['echo'], 'logcat -d -t 50');

    // Audit row appended.
    final head = await audit.head();
    expect(head, isNotNull);
    expect(head!.seq, 1);
  });

  // ── Param validation ──────────────────────────────────────────

  test('bad param → param_validation_failed', () async {
    await seedTier1();
    final r = await dispatcher.exec(
      templateId: 'diag.tail_logs',
      params: const {'lines': -1}, // below min
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.paramValidationFailed);
  });

  // ── Tier-2 gate cascade ───────────────────────────────────────

  test('tier-2 with no consent → user_consent_missing', () async {
    await seedTier2();
    await seedFreshRevocationList();
    await seedActiveCap();
    final r = await dispatcher.exec(
      templateId: 'pm.disable_user',
      params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.userConsentMissing);
  });

  test('tier-2 step-up op → step_up_required', () async {
    await seedTier2(requiresStepUp: true);
    await seedFreshRevocationList();
    await seedActiveCap();
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: 'cmdExec.control',
        grantedAt: DateTime.now().toUtc(),
      ),
    );
    final r = await dispatcher.exec(
      templateId: 'sys.reboot',
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.stepUpRequired);
  });

  test('tier-2 with stale revocation list → revocation_list_stale', () async {
    await seedTier2();
    // openAdminDatabase v3 auto-seeds revocation_meta with now() so a
    // fresh install isn't fail-closed before the periodic puller has
    // had a chance to run. Delete the seed to recreate the "never
    // pulled" state this invariant tests against.
    await db.delete('revocation_meta');
    await seedActiveCap();
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: 'cmdExec.control',
        grantedAt: DateTime.now().toUtc(),
      ),
    );
    final r = await dispatcher.exec(
      templateId: 'pm.disable_user',
      params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.revocationListStale);
  });

  test('tier-2 with revoked cert → cert_revoked', () async {
    await seedTier2();
    await seedFreshRevocationList();
    await revs.ingest([
      (
        certHash: _certHash,
        revokedAt: DateTime.now().toUtc(),
        reason: 'rotated',
      ),
    ]);
    await seedActiveCap();
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: 'cmdExec.control',
        grantedAt: DateTime.now().toUtc(),
      ),
    );
    final r = await dispatcher.exec(
      templateId: 'pm.disable_user',
      params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.certRevoked);
  });

  test('tier-2 with no session cap → session_cap_missing', () async {
    await seedTier2();
    await seedFreshRevocationList();
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: 'cmdExec.control',
        grantedAt: DateTime.now().toUtc(),
      ),
    );
    // No cap upserted.
    final r = await dispatcher.exec(
      templateId: 'pm.disable_user',
      params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
      currentSession: _session,
    );
    expect((r as AdminExecError).code, DispatchErrorCode.sessionCapMissing);
  });

  test(
    'tier-2 with cap not covering op → session_cap_does_not_cover_op',
    () async {
      await seedTier2();
      await seedFreshRevocationList();
      await seedActiveCap(opsAllowed: const {'other_op'});
      await consents.grant(
        AdminPermissionGrant(
          userId: _userId,
          appId: _appId,
          permissionId: 'cmdExec.control',
          grantedAt: DateTime.now().toUtc(),
        ),
      );
      final r = await dispatcher.exec(
        templateId: 'pm.disable_user',
        params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
        currentSession: _session,
      );
      expect(
        (r as AdminExecError).code,
        DispatchErrorCode.sessionCapDoesNotCoverOp,
      );
    },
  );

  test(
    'tier-2 with mismatched cap binding → session_cap_binding_mismatch',
    () async {
      await seedTier2();
      await seedFreshRevocationList();
      // Cap stored under a different VIN — simulates a leaked cap
      // replayed onto another car. Critical security test.
      await caps.upsert(
        StoredSessionCap(
          userId: _userId,
          deviceId: 'OTHERVIN',
          appId: _appId,
          certHash: _certHash,
          envelope: 'opaque',
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
          opsAllowed: const {'pm.disable_user'},
          stepUpOps: const {},
          renewBeforeSec: 86_400,
          fetchedAt: DateTime.now().toUtc(),
        ),
      );
      await consents.grant(
        AdminPermissionGrant(
          userId: _userId,
          appId: _appId,
          permissionId: 'cmdExec.control',
          grantedAt: DateTime.now().toUtc(),
        ),
      );
      // Session has _vin (WDB...), but the only stored cap is under
      // OTHERVIN — so .get() returns null. The mismatch test below
      // covers the actual binding-mismatch branch.
      await dispatcher.exec(
        templateId: 'pm.disable_user',
        params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
        currentSession: _session,
      );
      // ``.get()`` keys on (user, deviceId, app) so a stored-on-other-deviceId
      // row isn't found at all → maps to sessionCapMissing instead.
      // The "binding mismatch" branch fires when get() returns a row
      // whose internal binding fields differ — that's a corruption /
      // future-schema-drift case. Cover it with a forced upsert into
      // the right key but a different cert_hash:
      await caps.delete(userId: _userId, deviceId: 'OTHERVIN', appId: _appId);
      await caps.upsert(
        StoredSessionCap(
          userId: _userId,
          deviceId: _vin,
          appId: _appId,
          certHash: 'different-cert', // ← mismatch with currentSession.certHash
          envelope: 'opaque',
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
          opsAllowed: const {'pm.disable_user'},
          stepUpOps: const {},
          renewBeforeSec: 86_400,
          fetchedAt: DateTime.now().toUtc(),
        ),
      );
      final r2 = await dispatcher.exec(
        templateId: 'pm.disable_user',
        params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
        currentSession: _session,
      );
      expect(
        (r2 as AdminExecError).code,
        DispatchErrorCode.sessionCapBindingMismatch,
      );
    },
  );

  test('tier-2 happy path — every gate passes, op runs + audits', () async {
    await seedTier2();
    await seedFreshRevocationList();
    await seedActiveCap();
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: 'cmdExec.control',
        grantedAt: DateTime.now().toUtc(),
      ),
    );
    final r = await dispatcher.exec(
      templateId: 'pm.disable_user',
      params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
      currentSession: _session,
    );
    expect(r, isA<AdminExecOk>());
    expect(
      (r as AdminExecOk).data['echo'],
      'pm disable-user --user 0 "com.byd.trafficmonitor"',
    );

    // Audit + counter both bumped.
    final head = await audit.head();
    expect(head!.seq, 1);
    final counters = await audit.opCountersForDay();
    expect(counters['pm.disable_user'], 1);
  });

  // ── Cap envelope never leaks ──────────────────────────────────

  test(
    'cap envelope is NEVER part of the result returned to the mini-app',
    () async {
      await seedTier2();
      await seedFreshRevocationList();
      await seedActiveCap();
      await consents.grant(
        AdminPermissionGrant(
          userId: _userId,
          appId: _appId,
          permissionId: 'cmdExec.control',
          grantedAt: DateTime.now().toUtc(),
        ),
      );
      final r = await dispatcher.exec(
        templateId: 'pm.disable_user',
        params: const {'user': 0, 'package': 'com.byd.trafficmonitor'},
        currentSession: _session,
      );
      final json = r.toJson();
      final asString = json.toString();
      // The envelope was 'opaque' in the seed; it must not appear in
      // the response, and neither must the cap's binding fields.
      expect(asString.contains('opaque'), isFalse);
      // The hosting layer's binding stays inside the host. The
      // mini-app sees only ``echo`` + ``op``.
      expect(asString.contains('cert_hash'), isFalse);
    },
  );
}
