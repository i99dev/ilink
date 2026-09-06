import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/revocation_list_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late RevocationListStore store;
  late Database db;

  setUp(() async {
    db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = RevocationListStore(db);
    addTearDown(db.close);
  });

  test('ingest + isRevoked round-trips', () async {
    await store.ingest([
      (
        certHash: 'compromised',
        revokedAt: DateTime.utc(2026, 5, 18),
        reason: 'leak',
      ),
    ]);
    expect(await store.isRevoked('compromised'), isTrue);
    expect(await store.isRevoked('safe'), isFalse);
  });

  test('ingest is idempotent (re-pull replaces row)', () async {
    final ts = DateTime.utc(2026, 5, 18);
    await store.ingest([(certHash: 'x', revokedAt: ts, reason: 'a')]);
    await store.ingest([(certHash: 'x', revokedAt: ts, reason: 'b')]);
    expect(await store.isRevoked('x'), isTrue);
  });

  test('setMeta + meta round-trips', () async {
    await store.setMeta(
      lastPulledAt: DateTime.utc(2026, 5, 18, 10),
      lastRevokedAt: DateTime.utc(2026, 5, 18, 5),
    );
    final m = await store.meta();
    expect(m, isNotNull);
    expect(m!.lastPulledAt, DateTime.utc(2026, 5, 18, 10));
    expect(m.lastRevokedAt, DateTime.utc(2026, 5, 18, 5));
  });

  test('isStale defaults to true with no meta row (fail-closed)', () async {
    // Critical security property: a device that's never pulled the
    // revocation list has NO basis to allow any tier-2 op. We must
    // return true (stale) here, not false.
    //
    // openAdminDatabase v3 auto-seeds the meta row with now() on
    // first open, so DELETE it here to recreate the "never pulled"
    // state this invariant is about.
    await db.delete('revocation_meta');
    expect(await store.isStale(), isTrue);
  });

  test('isStale is false within the 24h window', () async {
    final now = DateTime.utc(2026, 5, 18, 12);
    await store.setMeta(
      lastPulledAt: now.subtract(const Duration(hours: 23)),
      lastRevokedAt: now.subtract(const Duration(days: 1)),
    );
    expect(await store.isStale(now: now), isFalse);
  });

  test('isStale becomes true past 24h', () async {
    final now = DateTime.utc(2026, 5, 18, 12);
    await store.setMeta(
      lastPulledAt: now.subtract(const Duration(hours: 25)),
      lastRevokedAt: now.subtract(const Duration(days: 2)),
    );
    expect(await store.isStale(now: now), isTrue);
  });

  test('custom maxAge override works', () async {
    final now = DateTime.utc(2026, 5, 18, 12);
    await store.setMeta(
      lastPulledAt: now.subtract(const Duration(hours: 2)),
      lastRevokedAt: now.subtract(const Duration(hours: 6)),
    );
    // Tighter window — 1h max age — flips it to stale.
    expect(
      await store.isStale(maxAge: const Duration(hours: 1), now: now),
      isTrue,
    );
  });
}
