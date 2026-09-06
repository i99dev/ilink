/// Riverpod wiring for the admin-mini-app dispatcher.
///
/// Phase-9.1 wiring: the dispatcher and its backing SQLite stores are
/// constructed lazily through these providers and consumed by the
/// `MiniAppViewer`'s `_admin.exec` JS bridge handler. Before this
/// file existed the entire `admin_mini_apps` feature was orphaned —
/// the dispatcher was implemented but no provider, no UI, and no
/// bridge handler reached into it.
///
/// Tests inject overrides via the standard Riverpod `overrideWithValue`
/// pattern (see `admin_dispatcher_provider_test.dart`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/consent_repository.dart';
import '../data/db/admin_db.dart';
import '../data/db/audit_chain_store.dart';
import '../data/db/revocation_list_store.dart';
import '../data/db/session_cap_store.dart';
import '../data/db/template_catalog_store.dart';
import '../domain/admin_dispatcher.dart';

/// Resolves the on-device path for the admin SQLite file.
///
/// Production: app-support directory + the canonical filename. Tests
/// override the whole `adminDatabaseProvider` with an in-memory DB
/// rather than overriding the path — there's no need to expose this
/// as its own provider yet.
Future<String> _resolveAdminDbPath() async {
  final base = await getApplicationSupportDirectory();
  return p.join(base.path, adminDbFilename);
}

/// Opens (and migrates) the admin DB. One per app process.
///
/// Held by Riverpod for the app lifetime; closed automatically when
/// the provider container disposes (e.g. test teardown).
final adminDatabaseProvider = FutureProvider<Database>((ref) async {
  final path = await _resolveAdminDbPath();
  final db = await openAdminDatabase(factory: databaseFactory, path: path);
  ref.onDispose(() async {
    try {
      await db.close();
    } catch (e, st) {
      // Closing twice or after a half-failed migration can throw;
      // it's never a user-visible problem so log and move on.
      debugPrint('admin DB close failed: $e\n$st');
    }
  });
  return db;
});

/// The dispatcher, fully wired against the admin DB and an executor.
///
/// Production wires [ProcessRunAdminOpExecutor] against ``Process.run``;
/// the shell command itself comes from the server-rendered
/// ``shell_template`` fetched by the orchestrator at install time
/// (``includeShell=1``). The dispatcher has already gated on session
/// cap + param validation by the time the executor runs.
final adminDispatcherProvider = FutureProvider<AdminMiniAppDispatcher>((
  ref,
) async {
  final db = await ref.watch(adminDatabaseProvider.future);
  return AdminMiniAppDispatcher(
    sessionCaps: SessionCapStore(db),
    auditChain: AuditChainStore(db),
    templates: TemplateCatalogStore(db),
    revocations: RevocationListStore(db),
    // Consent storage is currently in-memory — Phase-10 swaps to a
    // SQLite-backed table. Until then the consent grants don't
    // survive a restart, which is fine because no privileged
    // mini-app install flow ships yet (every tier-2 op fails the
    // session-cap gate first anyway).
    consents: InMemoryAdminConsentRepository(),
    executor: const ProcessRunAdminOpExecutor(),
  );
});
