/// Tests for [InMemoryAdminConsentRepository] — the consent layer
/// that the ``_admin.exec`` handler checks before dispatching any
/// privileged op.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/consent_repository.dart';

void main() {
  group('InMemoryAdminConsentRepository', () {
    late InMemoryAdminConsentRepository repo;

    setUp(() {
      repo = InMemoryAdminConsentRepository();
    });

    test('isGranted returns false for unknown grants', () async {
      expect(
        await repo.isGranted(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
        ),
        isFalse,
      );
    });

    test('grant + isGranted round-trips', () async {
      await repo.grant(
        AdminPermissionGrant(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );
      expect(
        await repo.isGranted(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
        ),
        isTrue,
      );
    });

    test('grants are scoped per (user, app, permission)', () async {
      // Critical: a grant for user A on app X must not leak to user
      // B. The cross-user case is the most subtle and the most
      // damaging if wrong.
      await repo.grant(
        AdminPermissionGrant(
          userId: 'A',
          appId: 'x',
          permissionId: 'cmdExec.read',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );
      expect(
        await repo.isGranted(
          userId: 'B',
          appId: 'x',
          permissionId: 'cmdExec.read',
        ),
        isFalse,
      );
      expect(
        await repo.isGranted(
          userId: 'A',
          appId: 'y',
          permissionId: 'cmdExec.read',
        ),
        isFalse,
      );
      expect(
        await repo.isGranted(
          userId: 'A',
          appId: 'x',
          permissionId: 'cmdExec.control',
        ),
        isFalse,
      );
    });

    test('revoke removes the grant', () async {
      await repo.grant(
        AdminPermissionGrant(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );
      await repo.revoke(userId: 'u', appId: 'a', permissionId: 'cmdExec.read');
      expect(
        await repo.isGranted(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
        ),
        isFalse,
      );
    });

    test('listForApp returns grants for that app only', () async {
      await repo.grant(
        AdminPermissionGrant(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.read',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );
      await repo.grant(
        AdminPermissionGrant(
          userId: 'u',
          appId: 'a',
          permissionId: 'cmdExec.control',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );
      await repo.grant(
        AdminPermissionGrant(
          userId: 'u',
          appId: 'b',
          permissionId: 'cmdExec.read',
          grantedAt: DateTime(2026, 5, 14),
        ),
      );

      final aGrants = await repo.listForApp(userId: 'u', appId: 'a');
      expect(aGrants.length, 2);
      expect(aGrants.map((g) => g.permissionId).toSet(), {
        'cmdExec.read',
        'cmdExec.control',
      });
    });
  });
}
