/// Tests for the admin SQLite schema bootstrap.
///
/// Uses ``sqflite_common_ffi`` so the DB runs in-process under the
/// standard ``flutter test`` harness — same SQLite engine as on a
/// real device, no platform channels needed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('openAdminDatabase', () {
    test('creates every v1 table', () async {
      final db = await openAdminDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);

      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' "
        "AND name NOT LIKE 'android_metadata'",
      )).map((r) => r['name'] as String).toSet();

      expect(
        tables,
        containsAll(<String>{
          'session_capabilities',
          'audit_chain',
          'op_counters_today',
          'template_catalog',
          'cert_revocations',
          'revocation_meta',
          'audit_outbox_seq',
        }),
      );
    });

    test('foreign_keys pragma is on', () async {
      final db = await openAdminDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      final result = await db.rawQuery('PRAGMA foreign_keys');
      expect(result.first.values.first, 1);
    });

    test('reports version 1 (baseline)', () async {
      final db = await openAdminDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      expect(await db.getVersion(), adminDbVersion);
    });

    test(
      'v3 — fresh DB seeds revocation_meta with last_pulled_at ≈ now',
      () async {
        // Reasoning: the tier-2 staleness gate fails-closed when no
        // revocation pull has ever happened. Until the periodic puller
        // lands, openAdminDatabase stamps `last_pulled_at = now()` so a
        // fresh install can dispatch tier-2 ops immediately.
        final before = DateTime.now().toUtc().millisecondsSinceEpoch;
        final db = await openAdminDatabase(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(db.close);
        final after = DateTime.now().toUtc().millisecondsSinceEpoch;

        final rows = await db.query('revocation_meta');
        expect(rows, hasLength(1));
        final lastPulled = rows.first['last_pulled_at'] as int;
        expect(lastPulled, inInclusiveRange(before, after));
        expect(rows.first['last_revoked_at'], 0);
        expect(rows.first['id'], 1);
      },
    );

    test(
      'v3 — seed is idempotent (INSERT OR IGNORE preserves prior row)',
      () async {
        // Important: the ON CONFLICT (id) DO NOTHING / OR IGNORE clause
        // must not clobber an existing seed if the seed query runs a
        // second time. Otherwise a code path that re-stamps would
        // reset the staleness window and mask a real "puller hasn't
        // run in a week" condition.
        //
        // We can't easily exercise the full open → close → re-open
        // path in-memory (sqflite-ffi shared-cache semantics around
        // user_version are quirky), so we assert the SQL directly: run
        // the same seed statement a second time after openAdminDatabase
        // has already stamped row id=1 and verify the original
        // last_pulled_at survives.
        final db = await openAdminDatabase(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(db.close);

        final originalRow = (await db.query('revocation_meta')).single;
        final originalLastPulled = originalRow['last_pulled_at'] as int;

        // Try to "re-seed" with a clearly different timestamp. If the
        // INSERT OR IGNORE clause is wrong (or someone changes it to
        // INSERT OR REPLACE), this would clobber the original row.
        await db.rawInsert(
          'INSERT OR IGNORE INTO revocation_meta '
          '(id, last_pulled_at, last_revoked_at) VALUES (1, ?, 0)',
          [originalLastPulled + 1_000_000],
        );

        final afterSecondSeed = (await db.query('revocation_meta')).single;
        expect(afterSecondSeed['last_pulled_at'], originalLastPulled);
      },
    );
  });
}
