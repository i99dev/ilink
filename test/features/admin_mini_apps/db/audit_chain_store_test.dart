/// SQLite-backed audit chain tests. Hash recipe must match the
/// in-memory ``LocalAuditChain`` and the backend's Python
/// ``audit_chain.py`` byte-for-byte.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/audit_chain_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AuditChainStore store;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = AuditChainStore(db);
    addTearDown(db.close);
  });

  group('append + chain integrity', () {
    test('first append starts from genesis', () async {
      final entry = await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'tail_logs',
        tier: 1,
        success: true,
        payload: const {'lines': 100},
      );
      expect(entry.seq, 1);
      expect(entry.prevHash, 'genesis');
    });

    test('subsequent appends link via prev_hash', () async {
      final r1 = await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'tail_logs',
        tier: 1,
        success: true,
        payload: const {},
      );
      final r2 = await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'restart_mqtt',
        tier: 2,
        success: true,
        payload: const {},
      );
      expect(r2.seq, 2);
      expect(r2.prevHash, r1.rowHash);
    });

    test('head reflects the latest append', () async {
      expect(await store.head(), isNull);
      final r1 = await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'x',
        tier: 1,
        success: true,
        payload: const {},
      );
      final h = await store.head();
      expect(h, isNotNull);
      expect(h!.seq, r1.seq);
      expect(h.hash, r1.rowHash);
    });
  });

  group('sliceForUpload', () {
    test('filters by tier', () async {
      for (final t in [1, 2, 1, 2]) {
        await store.append(
          userId: 'u1',
          appId: 'app',
          op: 'op-$t',
          tier: t,
          success: true,
          payload: const {},
        );
      }
      final tier2 = await store.sliceForUpload(tier: 2);
      expect(tier2.length, 2);
      expect(tier2.every((r) => r.tier == 2), isTrue);
    });

    test('filters by app_id (cross-app slice)', () async {
      await store.append(
        userId: 'u1',
        appId: 'app-a',
        op: 'x',
        tier: 1,
        success: true,
        payload: const {},
      );
      await store.append(
        userId: 'u1',
        appId: 'app-b',
        op: 'x',
        tier: 1,
        success: true,
        payload: const {},
      );
      final aOnly = await store.sliceForUpload(appId: 'app-a');
      expect(aOnly.length, 1);
      expect(aOnly.first.appId, 'app-a');
    });

    test('filters by time window', () async {
      final now = DateTime.utc(2026, 5, 18, 12);
      await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'old',
        tier: 1,
        success: true,
        payload: const {},
        occurredAt: now.subtract(const Duration(days: 5)),
      );
      await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'recent',
        tier: 1,
        success: true,
        payload: const {},
        occurredAt: now,
      );
      final lastDay = await store.sliceForUpload(
        from: now.subtract(const Duration(days: 1)),
      );
      expect(lastDay.map((r) => r.op).toList(), ['recent']);
    });

    test('returns rows ordered by seq ASC', () async {
      for (var i = 0; i < 5; i++) {
        await store.append(
          userId: 'u1',
          appId: 'app',
          op: 'op-$i',
          tier: 1,
          success: true,
          payload: const {},
        );
      }
      final all = await store.sliceForUpload();
      expect(all.map((r) => r.seq).toList(), [1, 2, 3, 4, 5]);
    });
  });

  group('retention', () {
    test('purgeOlderThan deletes old rows', () async {
      final old = DateTime.utc(2026, 5, 1);
      final fresh = DateTime.utc(2026, 5, 18);
      await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'old',
        tier: 1,
        success: true,
        payload: const {},
        occurredAt: old,
      );
      await store.append(
        userId: 'u1',
        appId: 'app',
        op: 'fresh',
        tier: 1,
        success: true,
        payload: const {},
        occurredAt: fresh,
      );
      final deleted = await store.purgeOlderThan(DateTime.utc(2026, 5, 10));
      expect(deleted, 1);
      final remaining = await store.sliceForUpload();
      expect(remaining.map((r) => r.op).toList(), ['fresh']);
    });
  });

  group('op counters', () {
    test('bumpOpCounter increments per day', () async {
      await store.bumpOpCounter('tail_logs');
      await store.bumpOpCounter('tail_logs');
      await store.bumpOpCounter('restart_mqtt');
      final counts = await store.opCountersForDay();
      expect(counts['tail_logs'], 2);
      expect(counts['restart_mqtt'], 1);
    });

    test('counters are scoped per UTC day', () async {
      // Simulate yesterday + today.
      final yesterday = DateTime.utc(2026, 5, 17, 23, 59);
      final today = DateTime.utc(2026, 5, 18, 0, 1);
      await store.bumpOpCounter('x', at: yesterday);
      await store.bumpOpCounter('x', at: today);
      final todayCounts = await store.opCountersForDay(at: today);
      expect(todayCounts['x'], 1); // not 2 — yesterday's row separate
    });
  });
}
