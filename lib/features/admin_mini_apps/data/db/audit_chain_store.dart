library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

const String _genesisPrevHash = 'genesis';

/// One row in the audit chain at-rest.
class StoredAuditEntry {
  const StoredAuditEntry({
    required this.seq,
    required this.occurredAt,
    required this.userId,
    required this.appId,
    required this.op,
    required this.tier,
    required this.success,
    required this.payload,
    required this.prevHash,
    required this.rowHash,
    this.idempotencyKey,
  });

  final int seq;
  final DateTime occurredAt;
  final String userId;
  final String appId;
  final String op;
  final int tier;
  final bool success;
  final Map<String, Object?> payload;
  final String prevHash;
  final String rowHash;

  /// SDK-supplied retry-protection key. Null on legacy rows (pre-Phase-9
  /// audit entries) and on caller paths that don't pass one. The
  /// dispatcher is the only production caller; tests may omit it.
  final String? idempotencyKey;
}

class AuditChainStore {
  AuditChainStore(this._db);

  final Database _db;

  /// Append a new audit row. Computes the hash atomically inside a
  /// transaction so two concurrent appenders can't both read the
  /// same ``last_hash`` and emit conflicting rows.
  ///
  /// [idempotencyKey] is the SDK-supplied retry token. When non-null
  /// AND non-empty, the (app_id, key) tuple is unique in the table —
  /// a duplicate insert raises a sqlite ``UNIQUE`` violation that
  /// the dispatcher catches as the "already executed" signal.
  /// Callers that don't participate in idempotency (legacy paths,
  /// host-internal audit entries) leave it null. Empty-string is
  /// normalised to null here so callers don't have to remember the
  /// distinction.
  Future<StoredAuditEntry> append({
    required String userId,
    required String appId,
    required String op,
    required int tier,
    required bool success,
    required Map<String, Object?> payload,
    DateTime? occurredAt,
    String? idempotencyKey,
  }) async {
    // Normalise empty → null. The "no key" semantics are identical
    // and the partial unique index would otherwise treat ('',  '')
    // as a real collision.
    final normalisedKey = (idempotencyKey == null || idempotencyKey.isEmpty)
        ? null
        : idempotencyKey;
    final ts = (occurredAt ?? DateTime.now().toUtc()).toUtc();
    // Truncate to seconds — matches the Python canonical-JSON format
    // (``occurred_at`` ISO string with ``Z`` suffix). Without this,
    // device-side sub-second precision would mismatch the server's
    // chain verifier on a forensic upload.
    final isoTs = '${ts.toIso8601String().split('.').first}Z';

    return _db.transaction((txn) async {
      // Read the chain head inside the txn so the prev_hash is
      // still valid when we INSERT.
      final head = await txn.query(
        'audit_chain',
        columns: ['seq', 'row_hash'],
        orderBy: 'seq DESC',
        limit: 1,
      );
      final prevSeq = head.isEmpty ? 0 : head.first['seq'] as int;
      final prevHash = head.isEmpty
          ? _genesisPrevHash
          : head.first['row_hash'] as String;

      final seq = prevSeq + 1;
      final hash = _hashRow(
        seq: seq,
        occurredAt: isoTs,
        op: op,
        tier: tier,
        success: success,
        payload: payload,
        prevHash: prevHash,
      );

      // Use the seq we computed; AUTOINCREMENT in the schema handles
      // the case where we omit it, but explicit-seq makes the txn
      // serialisation rule visible to a future reader.
      await txn.insert('audit_chain', {
        'seq': seq,
        'occurred_at': ts.millisecondsSinceEpoch,
        'user_id': userId,
        'app_id': appId,
        'op': op,
        'tier': tier,
        'success': success ? 1 : 0,
        'payload_json': jsonEncode(payload),
        'prev_hash': prevHash,
        'row_hash': hash,
        // Conditional map element omits the entry when [normalisedKey]
        // is null (legacy callers / no-idempotency callers). Keeps
        // the column NULL rather than `''`, so the partial unique
        // index treats "no key" callers as exempt instead of
        // colliding with each other.
        'idempotency_key': ?normalisedKey,
      });

      return StoredAuditEntry(
        seq: seq,
        occurredAt: ts,
        userId: userId,
        appId: appId,
        op: op,
        tier: tier,
        success: success,
        payload: payload,
        prevHash: prevHash,
        rowHash: hash,
        // Mirror the row that was actually persisted — null when the
        // caller passed null OR empty.
        idempotencyKey: normalisedKey,
      );
    });
  }

  /// Look up an existing audit row by (app_id, idempotency_key). The
  /// dispatcher calls this BEFORE executing an op; a hit means the
  /// op already ran and we should return the cached envelope rather
  /// than dispatch again.
  ///
  /// Returns null when no matching row exists OR when [idempotencyKey]
  /// is empty (treats empty as "no key" — keeps the call site simple).
  Future<StoredAuditEntry?> findByIdempotencyKey({
    required String appId,
    required String idempotencyKey,
  }) async {
    if (idempotencyKey.isEmpty) return null;
    final rows = await _db.query(
      'audit_chain',
      where: 'app_id = ? AND idempotency_key = ?',
      whereArgs: [appId, idempotencyKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Latest seq + hash. Used by the metadata sync to build the
  /// payload it forwards to the server.
  Future<({int seq, String hash})?> head() async {
    final rows = await _db.query(
      'audit_chain',
      columns: ['seq', 'row_hash'],
      orderBy: 'seq DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      seq: rows.first['seq'] as int,
      hash: rows.first['row_hash'] as String,
    );
  }

  /// Slice for forensic upload. Filters by tier + time window +
  /// app_id; matches the JSON ``filters`` shape the server's
  /// ``ForensicAuditRequest`` carries.
  Future<List<StoredAuditEntry>> sliceForUpload({
    int? tier,
    DateTime? from,
    DateTime? to,
    String? appId,
    int? limit,
  }) async {
    final where = <String>[];
    final args = <Object>[];
    if (tier != null) {
      where.add('tier = ?');
      args.add(tier);
    }
    if (from != null) {
      where.add('occurred_at >= ?');
      args.add(from.toUtc().millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('occurred_at <= ?');
      args.add(to.toUtc().millisecondsSinceEpoch);
    }
    if (appId != null) {
      where.add('app_id = ?');
      args.add(appId);
    }
    final rows = await _db.query(
      'audit_chain',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'seq ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Retention sweep — delete rows older than [cutoff]. Returns the
  /// number deleted (logged + reported via the metadata sync).
  Future<int> purgeOlderThan(DateTime cutoff) async {
    return _db.delete(
      'audit_chain',
      where: 'occurred_at < ?',
      whereArgs: [cutoff.toUtc().millisecondsSinceEpoch],
    );
  }

  /// Bump the per-day op counter. Counters reset at the day
  /// boundary — the ``day_utc`` column distinguishes today's row
  /// from yesterday's so we never blow away history that the
  /// metadata sync is about to forward.
  Future<void> bumpOpCounter(String op, {DateTime? at}) async {
    final ts = (at ?? DateTime.now().toUtc()).toUtc();
    final dayUtc =
        '${ts.year.toString().padLeft(4, '0')}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
    await _db.rawInsert(
      '''
      INSERT INTO op_counters_today (op, day_utc, count)
      VALUES (?, ?, 1)
      ON CONFLICT(op, day_utc) DO UPDATE SET count = count + 1
      ''',
      [op, dayUtc],
    );
  }

  /// Snapshot of today's counters. Forwarded inside the metadata-
  /// sync payload so the anomaly detector can flag e.g. "100
  /// restart_mqtt today on this device."
  Future<Map<String, int>> opCountersForDay({DateTime? at}) async {
    final ts = (at ?? DateTime.now().toUtc()).toUtc();
    final dayUtc =
        '${ts.year.toString().padLeft(4, '0')}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
    final rows = await _db.query(
      'op_counters_today',
      where: 'day_utc = ?',
      whereArgs: [dayUtc],
    );
    return {for (final r in rows) r['op'] as String: r['count'] as int};
  }

  /// Drop counter rows older than [cutoffDays]. Idempotent.
  Future<int> purgeOldCounters({int cutoffDays = 7}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: cutoffDays));
    final dayUtc =
        '${cutoff.year.toString().padLeft(4, '0')}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    return _db.delete(
      'op_counters_today',
      where: 'day_utc < ?',
      whereArgs: [dayUtc],
    );
  }

  static StoredAuditEntry _fromRow(Map<String, Object?> row) {
    return StoredAuditEntry(
      seq: row['seq'] as int,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
        row['occurred_at'] as int,
        isUtc: true,
      ),
      userId: row['user_id'] as String,
      appId: row['app_id'] as String,
      op: row['op'] as String,
      tier: row['tier'] as int,
      success: (row['success'] as int) == 1,
      payload: Map<String, Object?>.from(
        jsonDecode(row['payload_json'] as String) as Map,
      ),
      prevHash: row['prev_hash'] as String,
      rowHash: row['row_hash'] as String,
      idempotencyKey: row['idempotency_key'] as String?,
    );
  }
}

// ── Hash recipe ────────────────────────────────────────────────────

String _hashRow({
  required int seq,
  required String occurredAt,
  required String op,
  required int tier,
  required bool success,
  required Map<String, Object?> payload,
  required String prevHash,
}) {
  final canonical = _canonicalJsonBytes(<String, Object?>{
    'seq': seq,
    'occurred_at': occurredAt,
    'op': op,
    'tier': tier,
    'success': success,
    'payload': payload,
    'prev_hash': prevHash,
  });
  return sha256.convert(canonical).toString();
}

List<int> _canonicalJsonBytes(Map<String, Object?> data) =>
    utf8.encode(_canonical(data));

String _canonical(Object? value) {
  if (value is Map) {
    final sortedKeys = value.keys.cast<String>().toList()..sort();
    final entries = <String>[];
    for (final k in sortedKeys) {
      entries.add('${jsonEncode(k)}:${_canonical(value[k])}');
    }
    return '{${entries.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonical).join(',')}]';
  }
  return jsonEncode(value);
}
