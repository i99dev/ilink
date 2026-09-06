/// SQLite-backed CRUD on the session-cap state.
///
/// One row per ``(user_id, deviceId, app_id)`` tuple. Phase-8 issued the
/// cap; this store persists it across reboots so the dispatcher can
/// reach for it on every privileged op without re-fetching from
/// the backend until expiry or revocation.
///
/// Mini-apps DO NOT have access to this store — only the Flutter
/// host's ``AdminMiniAppDispatcher`` consults it. The cap envelope
/// never leaves the host process.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// In-memory shape the dispatcher consumes. JSON fields are decoded
/// once at load — the dispatcher reads ``opsAllowed`` / ``stepUpOps``
/// as Sets for O(1) membership.
class StoredSessionCap {
  StoredSessionCap({
    required this.userId,
    required this.deviceId,
    required this.appId,
    required this.certHash,
    required this.envelope,
    required this.expiresAt,
    required Set<String> opsAllowed,
    required Set<String> stepUpOps,
    required this.renewBeforeSec,
    required this.fetchedAt,
  }) : opsAllowed = Set.unmodifiable(opsAllowed),
       stepUpOps = Set.unmodifiable(stepUpOps);

  final String userId;
  final String deviceId;
  final String appId;
  final String certHash;
  final String envelope;
  final DateTime expiresAt;
  final Set<String> opsAllowed;
  final Set<String> stepUpOps;
  final int renewBeforeSec;
  final DateTime fetchedAt;

  bool isExpired({DateTime? now}) =>
      (now ?? DateTime.now().toUtc()).isAfter(expiresAt);

  bool isStale({DateTime? now}) {
    final cur = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return cur >= expiresAt.millisecondsSinceEpoch - renewBeforeSec * 1000;
  }
}

class SessionCapStore {
  SessionCapStore(this._db);

  final Database _db;

  /// Insert-or-replace by ``(user_id, deviceId, app_id)`` PK. Used at
  /// install (insert) AND renewal (replace) — the SQLite ``INSERT
  /// OR REPLACE`` semantics match the server's "update in place if
  /// active row exists" rule from ``service.issue_session_cap``.
  Future<void> upsert(StoredSessionCap cap) async {
    await _db.insert('session_capabilities', {
      'user_id': cap.userId,
      'device_id': cap.deviceId,
      'app_id': cap.appId,
      'cert_hash': cap.certHash,
      'envelope': cap.envelope,
      'expires_at': cap.expiresAt.millisecondsSinceEpoch,
      'ops_allowed_json': jsonEncode(cap.opsAllowed.toList()),
      'step_up_ops_json': jsonEncode(cap.stepUpOps.toList()),
      'renew_before_sec': cap.renewBeforeSec,
      'fetched_at': cap.fetchedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Lookup hot path — every privileged op dispatch hits this.
  /// Returns the row if present (regardless of expiry); the
  /// dispatcher decides whether to use it or fall back.
  Future<StoredSessionCap?> get({
    required String userId,
    required String deviceId,
    required String appId,
  }) async {
    final rows = await _db.query(
      'session_capabilities',
      where: 'user_id = ? AND device_id = ? AND app_id = ?',
      whereArgs: [userId, deviceId, appId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// All caps for a (user, deviceId) pair — useful for the Settings
  /// "your installed admin mini-apps" panel.
  Future<List<StoredSessionCap>> listForUserDevice({
    required String userId,
    required String deviceId,
  }) async {
    final rows = await _db.query(
      'session_capabilities',
      where: 'user_id = ? AND device_id = ?',
      whereArgs: [userId, deviceId],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Delete one cap. Used on:
  ///   * server-side revocation propagated via ``cert_revocations``
  ///   * user uninstalling the mini-app
  ///   * pairing cycle (re-pair clears all caps for the previous VIN)
  Future<void> delete({
    required String userId,
    required String deviceId,
    required String appId,
  }) async {
    await _db.delete(
      'session_capabilities',
      where: 'user_id = ? AND device_id = ? AND app_id = ?',
      whereArgs: [userId, deviceId, appId],
    );
  }

  /// Sweep every cap whose ``cert_hash`` is in the revocation list.
  /// Called from the hourly revocation pull's tail. Returns the
  /// number of caps deleted (for logging + the metadata-sync's
  /// gap-detector signal).
  Future<int> deleteByCertHash(String certHash) async {
    return _db.delete(
      'session_capabilities',
      where: 'cert_hash = ?',
      whereArgs: [certHash],
    );
  }

  static StoredSessionCap _fromRow(Map<String, Object?> row) {
    return StoredSessionCap(
      userId: row['user_id'] as String,
      deviceId: row['device_id'] as String,
      appId: row['app_id'] as String,
      certHash: row['cert_hash'] as String,
      envelope: row['envelope'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        row['expires_at'] as int,
        isUtc: true,
      ),
      opsAllowed: Set<String>.from(
        jsonDecode(row['ops_allowed_json'] as String) as List,
      ),
      stepUpOps: Set<String>.from(
        jsonDecode(row['step_up_ops_json'] as String) as List,
      ),
      renewBeforeSec: row['renew_before_sec'] as int,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        row['fetched_at'] as int,
        isUtc: true,
      ),
    );
  }
}
