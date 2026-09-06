/// SQLite-backed store for `boot.write` declarations.
///
/// One row per (user, deviceId, app, packageName) — each row is a
/// mini-app's request to auto-launch a package on cold boot. The
/// host's [BootLauncher] reads every row matching the active
/// (user, deviceId) at boot, de-dupes by `(packageName, displayId)`, and
/// fires the launches.
///
/// Lives alongside `session_capabilities`, `audit_chain`, etc. in
/// the admin DB — it's per-device runtime state that survives
/// reboots, not something the catalog server owns.
library;

import 'dart:async';

import 'package:sqflite/sqflite.dart';

class BootEntry {
  const BootEntry({
    required this.userId,
    required this.deviceId,
    required this.appId,
    required this.packageName,
    required this.displayId,
    required this.setAtMs,
    this.route,
  });

  final String userId;
  final String deviceId;
  final String appId;
  final String packageName;

  /// `-1` means default (IVI) display; otherwise an Android display
  /// id (passenger, cluster slots).
  final int displayId;
  final String? route;
  final int setAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'packageName': packageName,
    'displayId': displayId,
    'setAtMs': setAtMs,
    if (route != null) 'route': route,
  };

  static BootEntry fromRow(Map<String, Object?> row) => BootEntry(
    userId: row['user_id']! as String,
    deviceId: row['device_id']! as String,
    appId: row['app_id']! as String,
    packageName: row['package_name']! as String,
    displayId: (row['display_id']! as num).toInt(),
    route: row['route'] as String?,
    setAtMs: (row['set_at']! as num).toInt(),
  );
}

class BootStore {
  BootStore(this._db);
  final Database _db;

  /// Insert or replace one row. Returns the entry written.
  Future<BootEntry> set({
    required String userId,
    required String deviceId,
    required String appId,
    required String packageName,
    required int displayId,
    String? route,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    await _db.insert('boot_apps', <String, Object?>{
      'user_id': userId,
      'device_id': deviceId,
      'app_id': appId,
      'package_name': packageName,
      'display_id': displayId,
      'route': route,
      'set_at': ts,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return BootEntry(
      userId: userId,
      deviceId: deviceId,
      appId: appId,
      packageName: packageName,
      displayId: displayId,
      route: route,
      setAtMs: ts,
    );
  }

  /// All declarations for one mini-app under (user, deviceId). The mini-app
  /// only sees its own rows — there's no cross-app listing surface.
  Future<List<BootEntry>> listForApp({
    required String userId,
    required String deviceId,
    required String appId,
  }) async {
    final rows = await _db.query(
      'boot_apps',
      where: 'user_id = ? AND device_id = ? AND app_id = ?',
      whereArgs: [userId, deviceId, appId],
      orderBy: 'package_name ASC',
    );
    return rows.map(BootEntry.fromRow).toList(growable: false);
  }

  /// All boot declarations under (user, deviceId) across every mini-app.
  /// Used by [BootLauncher] at cold-start to enumerate everything to
  /// launch. The launcher de-dupes by `(packageName, displayId)`.
  Future<List<BootEntry>> listAllFor({
    required String userId,
    required String deviceId,
  }) async {
    final rows = await _db.query(
      'boot_apps',
      where: 'user_id = ? AND device_id = ?',
      whereArgs: [userId, deviceId],
      orderBy: 'app_id, package_name',
    );
    return rows.map(BootEntry.fromRow).toList(growable: false);
  }

  /// Delete one (user, deviceId, app, package) tuple. No-op if absent.
  /// Returns the number of rows deleted (0 or 1).
  Future<int> unset({
    required String userId,
    required String deviceId,
    required String appId,
    required String packageName,
  }) async {
    return _db.delete(
      'boot_apps',
      where:
          'user_id = ? AND device_id = ? AND app_id = ? AND package_name = ?',
      whereArgs: [userId, deviceId, appId, packageName],
    );
  }

  /// Wipe every declaration for one mini-app. Used on uninstall —
  /// otherwise stale rows from a removed mini-app would keep
  /// triggering launches. Returns the row count deleted.
  Future<int> clearForApp({required String appId}) async {
    return _db.delete('boot_apps', where: 'app_id = ?', whereArgs: [appId]);
  }
}
