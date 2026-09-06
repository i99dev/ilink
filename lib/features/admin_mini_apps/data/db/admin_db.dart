/// Centralised SQLite-backed store for all admin-mini-app runtime
/// state.
///
/// Phase-9 design: the Flutter host owns one SQLite database that
/// holds **everything** mini-apps need to evaluate privileged ops —
/// session caps, audit chain, op counters, template catalog, cert
/// revocation list. Mini-apps never touch any of it; they call
/// ``_admin.exec(templateId, params)`` and the host attaches the
/// right cap, audits the call, and returns the result.
///
/// Why one DB:
///   * One revocation pull serves every installed mini-app.
///   * One audit chain across apps = unified forensic upload.
///   * One template catalog cached per dev cert.
///   * No mini-app's WebView holds a cap copy that could leak.
///
/// Encryption note (deferred):
///   In production this DB should be opened with
///   ``sqflite_sqlcipher`` and a key derived from the OS keystore
///   (Keystore on Android, Keychain on iOS). Phase 9 ships with
///   plaintext sqflite + an injectable factory so the swap to
///   sqflite_sqlcipher is one constructor change. The store classes
///   below DO NOT depend on the cipher being on/off — they work
///   against either factory.
library;

import 'dart:async';

import 'package:sqflite/sqflite.dart';

const String adminDbFilename = 'ilink_admin.sqlite';

/// Bumped to 2 in Phase-9.1 to add `audit_chain.idempotency_key` for
/// retry-safe `_admin.exec` dispatch. The column is nullable so legacy
/// rows from v1 still load, and the unique index is partial (only
/// rows with a non-null key participate).
///
/// v4 (Phase C): adds `boot_apps` table for the `boot.write` family —
/// one row per (user, deviceId, app, packageName) declaring which packages
/// to launch on cold-start, on which display.
///
/// v5 (device-id rename, pre-release cutover per
/// RENAME_BYD_DEVICE_ID_CONTRACT.md): rename the `vin` column on
/// `session_capabilities` + `boot_apps` to `device_id`. Both are
/// per-session caches, NOT durable user data — the migration drops
/// and recreates the tables; the next backend fetch / boot.write
/// declaration re-populates them.
const int adminDbVersion = 5;

/// Schema bootstrap. Single-version baseline — when we bump
/// [adminDbVersion], add an ``ALTER TABLE`` block under the new
/// version number's ``onUpgrade`` branch.
const List<String> _schemaV1 = [
  // ── session_capabilities — Phase 8 install-time cap, persisted ──
  '''
  CREATE TABLE session_capabilities (
    user_id    TEXT NOT NULL,
    device_id  TEXT NOT NULL,
    app_id     TEXT NOT NULL,
    cert_hash  TEXT NOT NULL,
    envelope   TEXT NOT NULL,
    expires_at INTEGER NOT NULL,    -- epoch millis (UTC)
    ops_allowed_json TEXT NOT NULL,
    step_up_ops_json TEXT NOT NULL,
    renew_before_sec INTEGER NOT NULL,
    fetched_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, device_id, app_id)
  )
  ''',

  // ── audit_chain — Phase 6 hash-chained event log ────────────────
  // ``idempotency_key`` (Phase-9.1) is what the SDK sends on every
  // ``_admin.exec`` call. The dispatcher uses (app_id, key) to detect
  // a replay and return the prior result instead of re-executing.
  // NOT in the hash recipe — replay protection is metadata, the
  // chain still records exactly what happened.
  '''
  CREATE TABLE audit_chain (
    seq             INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at     INTEGER NOT NULL,    -- epoch millis (UTC)
    user_id         TEXT NOT NULL,
    app_id          TEXT NOT NULL,
    op              TEXT NOT NULL,
    tier            INTEGER NOT NULL,
    success         INTEGER NOT NULL,    -- bool 0/1
    payload_json    TEXT NOT NULL,
    prev_hash       TEXT NOT NULL,
    row_hash        TEXT NOT NULL,
    idempotency_key TEXT                 -- nullable; SDK ≥ Phase-9 always sets it
  )
  ''',
  // Forensic-upload + retention sweeps both want this index.
  'CREATE INDEX ix_audit_chain_occurred_at ON audit_chain(occurred_at)',
  'CREATE INDEX ix_audit_chain_app_id ON audit_chain(app_id)',
  // Partial unique index: only rows with a non-null key participate.
  // Keeps legacy / non-idempotent appends free of an artificial
  // collision while still rejecting a duplicate (app_id, key) pair
  // when a retry races a still-running first attempt.
  'CREATE UNIQUE INDEX ix_audit_chain_idempotency '
      'ON audit_chain(app_id, idempotency_key) '
      'WHERE idempotency_key IS NOT NULL',

  // ── op_counters_today — for Phase 6 metadata sync ───────────────
  '''
  CREATE TABLE op_counters_today (
    op       TEXT NOT NULL,
    day_utc  TEXT NOT NULL,          -- YYYY-MM-DD
    count    INTEGER NOT NULL,
    PRIMARY KEY (op, day_utc)
  )
  ''',

  // ── template_catalog — Phase 7 templates, cached per cert hash ──
  '''
  CREATE TABLE template_catalog (
    cert_hash       TEXT NOT NULL,
    template_id     TEXT NOT NULL,
    permission_id   TEXT NOT NULL,
    tier            INTEGER NOT NULL,
    requires_step_up INTEGER NOT NULL,  -- bool 0/1
    category        TEXT NOT NULL,
    shell_template  TEXT NOT NULL,
    param_schema_json TEXT NOT NULL,
    description     TEXT,
    fetched_at      INTEGER NOT NULL,
    PRIMARY KEY (cert_hash, template_id)
  )
  ''',

  // ── cert_revocations — Phase 0/8 revocation list ────────────────
  '''
  CREATE TABLE cert_revocations (
    cert_hash      TEXT PRIMARY KEY,
    revoked_at     INTEGER NOT NULL,
    revoked_reason TEXT
  )
  ''',
  // ``last_pulled_at`` stays in a 1-row metadata table so a
  // fail-closed "stale revocation list" check is one query, not a
  // self-join on cert_revocations.
  '''
  CREATE TABLE revocation_meta (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    last_pulled_at INTEGER NOT NULL,
    last_revoked_at INTEGER NOT NULL    -- highest revoked_at seen, for incremental fetch
  )
  ''',

  // ── audit_outbox_seq — Phase 6 chain anchor ────────────────────
  // Mirror of the server-side ``device_audit_seq`` row, kept locally
  // for fast metadata-sync construction.
  '''
  CREATE TABLE audit_outbox_seq (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    last_seq    INTEGER NOT NULL,
    last_hash   TEXT NOT NULL
  )
  ''',

  // ── boot_apps — Phase C `boot.write` declarations ──────────────
  // Each row: a mini-app's request to auto-launch a package on cold
  // boot. The composite PK guards against a single mini-app
  // declaring the same package twice; different mini-apps are free
  // to declare the same package (the boot launcher de-dupes by
  // package_name + display_id at run time).
  //
  // `display_id = -1` means "default display" — the host's
  // BootLauncher uses Context.startActivity for that and the
  // am-start fallback for any non-default value, mirroring the
  // surface family's cluster-launch path.
  //
  // `route` is intentionally untyped here — when the launcher
  // resolves a package's main intent, route is just an extras
  // value the package can read on its own.
  '''
  CREATE TABLE boot_apps (
    user_id      TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    app_id       TEXT NOT NULL,
    package_name TEXT NOT NULL,
    display_id   INTEGER NOT NULL,
    route        TEXT,
    set_at       INTEGER NOT NULL,
    PRIMARY KEY (user_id, device_id, app_id, package_name)
  )
  ''',
  'CREATE INDEX ix_boot_apps_app_id ON boot_apps(app_id)',
];

/// Opens (and migrates) the admin DB. Returns a ``Database`` ready
/// for the store classes. The ``factory`` argument lets tests pass
/// ``databaseFactoryFfi`` from ``sqflite_common_ffi`` without
/// touching production code.
Future<Database> openAdminDatabase({
  required DatabaseFactory factory,
  required String path,
}) async {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: adminDbVersion,
      onCreate: (db, version) async {
        // Apply the v1 baseline. Future versions will add their own
        // statements after a ``if (oldVersion < N) ...`` check inside
        // ``onUpgrade``.
        for (final stmt in _schemaV1) {
          await db.execute(stmt);
        }
        // v3 — seed revocation_meta so a fresh install isn't treated
        // as "stale" before the periodic puller has had a chance to
        // run. See onUpgrade v3 block for rationale.
        await _seedRevocationMetaIfMissing(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Forward-only migrations. Each block is idempotent so a
        // half-applied migration replays cleanly.
        if (oldVersion < 2) {
          // v2 — idempotency key on audit_chain.
          // ``ALTER TABLE … ADD COLUMN`` is idempotent in the sense
          // that SQLite will throw if the column already exists, but
          // pragma user_version protects us: this branch only runs
          // when oldVersion was actually 1.
          await db.execute(
            'ALTER TABLE audit_chain ADD COLUMN idempotency_key TEXT',
          );
          await db.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS ix_audit_chain_idempotency '
            'ON audit_chain(app_id, idempotency_key) '
            'WHERE idempotency_key IS NOT NULL',
          );
        }
        if (oldVersion < 3) {
          // v3 — seed revocation_meta with `last_pulled_at = now()` so
          // the tier-2 staleness check (24h max) doesn't fail-closed
          // on devices that have never run a successful pull yet.
          // Treats a fresh install as "fresh state" — equivalent to
          // saying "nothing was revoked at install time, and we'll
          // refresh on the next periodic pull." This bridges the gap
          // until the periodic puller (`/admin-perms/runtime/cert-revocations`)
          // is wired into the host's startup loop.
          await _seedRevocationMetaIfMissing(db);
        }
        if (oldVersion < 4) {
          // v4 (Phase C) — boot_apps for `boot.write` family.
          // Note: the column is still `vin` at this revision; v5
          // drops + recreates the table with `device_id` instead.
          await db.execute('''
            CREATE TABLE IF NOT EXISTS boot_apps (
              user_id      TEXT NOT NULL,
              vin          TEXT NOT NULL,
              app_id       TEXT NOT NULL,
              package_name TEXT NOT NULL,
              display_id   INTEGER NOT NULL,
              route        TEXT,
              set_at       INTEGER NOT NULL,
              PRIMARY KEY (user_id, vin, app_id, package_name)
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS ix_boot_apps_app_id '
            'ON boot_apps(app_id)',
          );
        }
        if (oldVersion < 5) {
          // v5 — `vin` -> `device_id` rename on both
          // `session_capabilities` and `boot_apps`. Per the rename
          // contract these are per-session caches (not durable user
          // data): drop and recreate. The next backend fetch /
          // boot.write declaration re-populates them with the
          // prefixed canonical device id.
          await db.execute('DROP TABLE IF EXISTS session_capabilities');
          await db.execute('DROP TABLE IF EXISTS boot_apps');
          await db.execute('DROP INDEX IF EXISTS ix_boot_apps_app_id');
          await db.execute('''
            CREATE TABLE session_capabilities (
              user_id    TEXT NOT NULL,
              device_id  TEXT NOT NULL,
              app_id     TEXT NOT NULL,
              cert_hash  TEXT NOT NULL,
              envelope   TEXT NOT NULL,
              expires_at INTEGER NOT NULL,
              ops_allowed_json TEXT NOT NULL,
              step_up_ops_json TEXT NOT NULL,
              renew_before_sec INTEGER NOT NULL,
              fetched_at INTEGER NOT NULL,
              PRIMARY KEY (user_id, device_id, app_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE boot_apps (
              user_id      TEXT NOT NULL,
              device_id    TEXT NOT NULL,
              app_id       TEXT NOT NULL,
              package_name TEXT NOT NULL,
              display_id   INTEGER NOT NULL,
              route        TEXT,
              set_at       INTEGER NOT NULL,
              PRIMARY KEY (user_id, device_id, app_id, package_name)
            )
          ''');
          await db.execute(
            'CREATE INDEX ix_boot_apps_app_id ON boot_apps(app_id)',
          );
        }
      },
      onConfigure: (db) async {
        // Foreign-key enforcement is opt-in on SQLite. We don't
        // declare FKs today (cross-table constraints kept to a
        // minimum — auditing reads can survive an orphan), but turn
        // it on so future migrations get the safety net for free.
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

Future<void> _seedRevocationMetaIfMissing(Database db) async {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  await db.rawInsert(
    'INSERT OR IGNORE INTO revocation_meta '
    '(id, last_pulled_at, last_revoked_at) VALUES (1, ?, 0)',
    [now],
  );
}
