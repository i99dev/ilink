/// Tests for [MiniAppGate.gateTier2] — focused on the `requireBinding`
/// flag that selects between the legacy `_admin.exec` binding model
/// (cert + session cap) and the new family path's manifest-backed
/// model (catalog install + bundle hash).
///
/// Other gate behaviour (consent, step-up, revocation freshness) is
/// covered indirectly by `family_executor_test.dart` and
/// `admin_dispatcher_test.dart`; this suite asserts only the bits
/// the new flag changes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/consent_repository.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/revocation_list_store.dart';
import 'package:ilink/features/admin_mini_apps/data/db/session_cap_store.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/admin_mini_apps/domain/mini_app_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _userId = 'u-gate';
const _vin = 'VIN-GATE';
const _appId = 'app-gate';
const _certHash = 'cert-gate';

const _session = AdminSession(
  userId: _userId,
  deviceId: _vin,
  appId: _appId,
  certHash: _certHash,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late SessionCapStore caps;
  late RevocationListStore revs;
  late InMemoryAdminConsentRepository consents;
  late MiniAppGate gate;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    caps = SessionCapStore(db);
    revs = RevocationListStore(db);
    // openAdminDatabase v3 already seeds revocation_meta with
    // last_pulled_at = now, so the staleness check passes by default.
    consents = InMemoryAdminConsentRepository();
    gate = MiniAppGate(
      sessionCaps: caps,
      revocations: revs,
      consents: consents,
    );
    addTearDown(db.close);
  });

  Future<void> grantConsent(String permissionId) async {
    await consents.grant(
      AdminPermissionGrant(
        userId: _userId,
        appId: _appId,
        permissionId: permissionId,
        grantedAt: DateTime.now().toUtc(),
      ),
    );
  }

  group('requireBinding: true (legacy _admin.exec path)', () {
    test('rejects when no session cap exists', () async {
      await grantConsent('cmdExec.read');
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'cmdExec.read',
        requiresStepUp: false,
        op: 'cmdExec.read.foo',
      );
      expect(r, isNotNull);
      expect(r!.code, DispatchErrorCode.sessionCapMissing);
    });

    test('rejects when developer cert is revoked', () async {
      await grantConsent('cmdExec.read');
      await revs.ingest([
        (
          certHash: _certHash,
          revokedAt: DateTime.now().toUtc(),
          reason: 'test',
        ),
      ]);
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'cmdExec.read',
        requiresStepUp: false,
        op: 'cmdExec.read.foo',
      );
      expect(r, isNotNull);
      expect(r!.code, DispatchErrorCode.certRevoked);
    });

    test(
      'default requireBinding is true (back-compat for _admin.exec)',
      () async {
        // Caller that omits the param should still get the cap check.
        await grantConsent('cmdExec.read');
        final r = await gate.gateTier2(
          session: _session,
          permissionId: 'cmdExec.read',
          requiresStepUp: false,
          op: 'cmdExec.read.foo',
          // requireBinding intentionally omitted — defaults to true.
        );
        expect(r?.code, DispatchErrorCode.sessionCapMissing);
      },
    );

    test(
      'rejects step_up_required for destructive ops on legacy path',
      () async {
        // Legacy invariant: gate refuses so the dispatcher fetches a
        // fresh per-action cap and re-calls. Family path inverts this
        // (see "passes when step-up required" below).
        await grantConsent('cmdExec.write');
        final r = await gate.gateTier2(
          session: _session,
          permissionId: 'cmdExec.write',
          requiresStepUp: true,
          op: 'cmdExec.write.foo',
          // requireBinding defaults to true.
        );
        expect(r?.code, DispatchErrorCode.stepUpRequired);
      },
    );
  });

  group('requireBinding: false (family path)', () {
    test('passes without a session cap', () async {
      // Family path's binding is the catalog install (manifest-backed
      // consent + bundle hash). No cap exists for the session, but
      // gate should accept.
      await grantConsent('surface.write');
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'surface.write',
        requiresStepUp: false,
        op: 'surface.create',
        requireBinding: false,
      );
      expect(r, isNull);
    });

    test('skips cert revocation check', () async {
      // Even if the same cert hash is in cert_revocations, family
      // path doesn't gate on it — there's no cert chain for a
      // bundle-hash-verified install.
      await grantConsent('surface.write');
      await revs.ingest([
        (
          certHash: _certHash,
          revokedAt: DateTime.now().toUtc(),
          reason: 'test',
        ),
      ]);
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'surface.write',
        requiresStepUp: false,
        op: 'surface.create',
        requireBinding: false,
      );
      expect(r, isNull);
    });

    test('still rejects when consent missing', () async {
      // Family path drops cert + cap but keeps step 1 (consent) —
      // the manifest-backed adapter is what populates this in prod.
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'surface.write',
        requiresStepUp: false,
        op: 'surface.create',
        requireBinding: false,
      );
      expect(r?.code, DispatchErrorCode.userConsentMissing);
    });

    test(
      'passes when step-up required — manifest install IS the step-up',
      () async {
        // Family path's step-up semantic: install-time manifest
        // consent. Per-action caps would just be friction noise on a
        // 60Hz drag with no backend round-trip to attach one. The
        // handler's `requiresStepUp = true` flag stays truthful (the
        // op IS destructive); the gate routes enforcement to the
        // install-time consent that just got granted.
        await grantConsent('gesture.dispatch');
        final r = await gate.gateTier2(
          session: _session,
          permissionId: 'gesture.dispatch',
          requiresStepUp: true,
          op: 'gesture.dispatch.tap',
          requireBinding: false,
        );
        expect(r, isNull);
      },
    );

    test('local consent operations work after 48 hours offline', () async {
      // Local manifest grants do not depend on a retired certificate service.
      await revs.setMeta(
        lastPulledAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 48),
        ),
        lastRevokedAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 48),
        ),
      );
      await grantConsent('surface.write');
      final r = await gate.gateTier2(
        session: _session,
        permissionId: 'surface.write',
        requiresStepUp: false,
        op: 'surface.create',
        requireBinding: false,
      );
      expect(r, isNull);
    });
  });
}
