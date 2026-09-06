/// Tests for SessionCapStore.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/session_cap_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late SessionCapStore store;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = SessionCapStore(db);
    addTearDown(db.close);
  });

  StoredSessionCap cap({
    String userId = 'u1',
    String deviceId = 'WDB1234567',
    String appId = 'diagnostics-pro',
    String certHash = 'abc',
    Set<String>? opsAllowed,
    Set<String>? stepUpOps,
    DateTime? expiresAt,
  }) => StoredSessionCap(
    userId: userId,
    deviceId: deviceId,
    appId: appId,
    certHash: certHash,
    envelope: 'opaque-envelope',
    expiresAt: expiresAt ?? DateTime.utc(2026, 6, 17),
    opsAllowed: opsAllowed ?? {'pm.disable_user', 'diag.tail_logs'},
    stepUpOps: stepUpOps ?? {'sys.reboot'},
    renewBeforeSec: 86_400,
    fetchedAt: DateTime.utc(2026, 5, 18),
  );

  test('upsert + get round-trips', () async {
    await store.upsert(cap());
    final got = await store.get(
      userId: 'u1',
      deviceId: 'WDB1234567',
      appId: 'diagnostics-pro',
    );
    expect(got, isNotNull);
    expect(got!.opsAllowed, contains('pm.disable_user'));
    expect(got.stepUpOps, contains('sys.reboot'));
    expect(got.envelope, 'opaque-envelope');
  });

  test('upsert replaces on PK conflict (renewal in place)', () async {
    await store.upsert(cap(opsAllowed: {'pm.disable_user'}));
    await store.upsert(cap(opsAllowed: {'pm.disable_user', 'diag.tail_logs'}));
    final got = await store.get(
      userId: 'u1',
      deviceId: 'WDB1234567',
      appId: 'diagnostics-pro',
    );
    expect(got!.opsAllowed.length, 2);
  });

  test('get returns null for unknown tuple', () async {
    final got = await store.get(
      userId: 'nope',
      deviceId: 'nope',
      appId: 'nope',
    );
    expect(got, isNull);
  });

  test('listForUserDevice returns only that pair', () async {
    await store.upsert(cap(appId: 'app-a'));
    await store.upsert(cap(appId: 'app-b'));
    await store.upsert(cap(userId: 'u2', appId: 'app-c'));
    final list = await store.listForUserDevice(
      userId: 'u1',
      deviceId: 'WDB1234567',
    );
    expect(list.map((c) => c.appId).toSet(), {'app-a', 'app-b'});
  });

  test('delete removes one row', () async {
    await store.upsert(cap());
    await store.delete(
      userId: 'u1',
      deviceId: 'WDB1234567',
      appId: 'diagnostics-pro',
    );
    expect(
      await store.get(
        userId: 'u1',
        deviceId: 'WDB1234567',
        appId: 'diagnostics-pro',
      ),
      isNull,
    );
  });

  test('deleteByCertHash sweeps every cap with that hash', () async {
    await store.upsert(cap(certHash: 'compromised', appId: 'app-a'));
    await store.upsert(cap(certHash: 'compromised', appId: 'app-b'));
    await store.upsert(cap(certHash: 'safe', appId: 'app-c'));

    final deleted = await store.deleteByCertHash('compromised');
    expect(deleted, 2);
    final remaining = await store.listForUserDevice(
      userId: 'u1',
      deviceId: 'WDB1234567',
    );
    expect(remaining.length, 1);
    expect(remaining.first.certHash, 'safe');
  });

  test('isExpired predicate uses stored expires_at', () async {
    await store.upsert(cap(expiresAt: DateTime.utc(2020, 1, 1)));
    final got = await store.get(
      userId: 'u1',
      deviceId: 'WDB1234567',
      appId: 'diagnostics-pro',
    );
    expect(got!.isExpired(), isTrue);
  });

  test('isStale fires when within renew_before_sec window', () async {
    final expires = DateTime.utc(2026, 5, 25, 0, 0, 0);
    await store.upsert(cap(expiresAt: expires));
    final got = await store.get(
      userId: 'u1',
      deviceId: 'WDB1234567',
      appId: 'diagnostics-pro',
    );
    // 23 hours before expiry — inside the 24h renew window.
    final inWindow = expires.subtract(const Duration(hours: 23));
    expect(got!.isStale(now: inWindow), isTrue);
    // Two days before expiry — outside.
    final beforeWindow = expires.subtract(const Duration(days: 2));
    expect(got.isStale(now: beforeWindow), isFalse);
  });
}
