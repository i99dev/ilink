/// SQLite-backed cert revocation list — the device's local view of
/// what the backend says is dead.
///
/// Pulled hourly from ``GET /admin-perms/runtime/cert-revocations``
/// using the watermark stored in ``revocation_meta``. Every tier-2
/// dispatch consults this store before letting an op proceed; if
/// the list is older than 24h, the dispatcher fails closed (refuses
/// the op) on the assumption that we may have missed a revocation.
library;

import 'package:sqflite/sqflite.dart';

class RevocationListStore {
  RevocationListStore(this._db);

  final Database _db;

  /// Insert revoked certs from a server response. Idempotent — a
  /// re-pulled row replaces the existing one. The caller is
  /// responsible for advancing the watermark via [setMeta].
  Future<int> ingest(
    List<({String certHash, DateTime revokedAt, String? reason})> rows,
  ) async {
    if (rows.isEmpty) return 0;
    return _db.transaction((txn) async {
      var n = 0;
      for (final r in rows) {
        await txn.insert('cert_revocations', {
          'cert_hash': r.certHash,
          'revoked_at': r.revokedAt.toUtc().millisecondsSinceEpoch,
          'revoked_reason': r.reason,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        n++;
      }
      return n;
    });
  }

  /// Hot path on every tier-2 dispatch: is this cert revoked?
  Future<bool> isRevoked(String certHash) async {
    final rows = await _db.query(
      'cert_revocations',
      where: 'cert_hash = ?',
      whereArgs: [certHash],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Update the watermark + last-pull timestamp. Call after a
  /// successful pull, even if the response was empty.
  Future<void> setMeta({
    required DateTime lastPulledAt,
    required DateTime lastRevokedAt,
  }) async {
    await _db.rawInsert(
      '''
      INSERT INTO revocation_meta (id, last_pulled_at, last_revoked_at)
      VALUES (1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        last_pulled_at = excluded.last_pulled_at,
        last_revoked_at = excluded.last_revoked_at
      ''',
      [
        lastPulledAt.toUtc().millisecondsSinceEpoch,
        lastRevokedAt.toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  /// Read the watermark. Returns null if the device has never
  /// successfully pulled — the dispatcher treats null as "stale"
  /// and fails closed on tier-2.
  Future<({DateTime lastPulledAt, DateTime lastRevokedAt})?> meta() async {
    final rows = await _db.query('revocation_meta', limit: 1);
    if (rows.isEmpty) return null;
    return (
      lastPulledAt: DateTime.fromMillisecondsSinceEpoch(
        rows.first['last_pulled_at'] as int,
        isUtc: true,
      ),
      lastRevokedAt: DateTime.fromMillisecondsSinceEpoch(
        rows.first['last_revoked_at'] as int,
        isUtc: true,
      ),
    );
  }

  /// Fail-closed predicate: is the local revocation view stale
  /// (older than [maxAge]) or never-pulled? Tier-2 ops MUST refuse
  /// when this returns true — otherwise a device that's been
  /// offline for a week could still execute privileged ops with a
  /// week-old understanding of who's revoked.
  Future<bool> isStale({
    Duration maxAge = const Duration(hours: 24),
    DateTime? now,
  }) async {
    final m = await meta();
    if (m == null) return true;
    final cur = (now ?? DateTime.now().toUtc()).toUtc();
    return cur.difference(m.lastPulledAt) > maxAge;
  }
}
