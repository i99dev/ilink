/// Riverpod wiring for the bridge family registry + executor.
///
/// Two providers, one chokepoint:
///
///   * [bridgeFamilyRegistryProvider] — process-wide singleton of
///     [BridgeFamilyRegistry]. Populated at app bootstrap (`main.dart`)
///     by calling `..register(DisplayFamily())..register(...)` once.
///     Tests override with their own pre-populated registry.
///
///   * [familyExecutorProvider] — async because it depends on the
///     admin SQLite DB (audit chain). Built once on first read,
///     then cached for the app lifetime.
///
/// `mini_app_viewer.dart` reads the registry to enumerate handlers
/// at WebView-creation, and the executor for every family call.
///
/// Each call is checked against local owner consent for its exact bundle.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_mini_apps/data/db/audit_chain_store.dart';
import '../../admin_mini_apps/state/admin_dispatcher_provider.dart';
import '../bridge/bridge_family_registry.dart';
import '../bridge/family_executor.dart';
import '../data/local_mini_app_grants.dart';

/// Process-wide registry of [MiniAppFamily]. Concrete families call
/// `ref.read(bridgeFamilyRegistryProvider).register(...)` at app
/// bootstrap. Plain [Provider] (not [FutureProvider]) because
/// registration is synchronous and must complete before the first
/// WebView builds.
final bridgeFamilyRegistryProvider = Provider<BridgeFamilyRegistry>(
  (ref) => BridgeFamilyRegistry(),
);

/// Per-host [FamilyExecutor]. Wires the audit chain so every op is
/// journalled.
final familyExecutorProvider = FutureProvider<FamilyExecutor>((ref) async {
  final db = await ref.watch(adminDatabaseProvider.future);
  return FamilyExecutor(
    registry: ref.watch(bridgeFamilyRegistryProvider),
    auditChain: AuditChainStore(db),
    authorize: (session, scope) => ref
        .read(localMiniAppGrantsProvider)
        .allows(session.appId, session.bundleSha256, scope),
  );
});
