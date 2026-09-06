/// Per-user × per-app × per-permission consent grants.
///
/// Layer-2 (CONSENT) of the three-layer admin-perms model. Stored
/// only on-device — the server never sees these. Revocation is
/// instantaneous (delete the row); the server-gated tier-2 path
/// also re-reads the user's consent at action time so the round-trip
/// stays consistent with the device's local state.
///
/// PHASE 4 SCAFFOLD: this skeleton holds an in-memory map. The
/// production rev wires SharedPreferences (or a small SQLite
/// backing) — interface stays identical so the swap is one-file.
library;

/// One stored grant. Tracks the per-permission decision the user made
/// at install time (``Allow All`` / ``Customize`` / ``Deny`` flow).
class AdminPermissionGrant {
  const AdminPermissionGrant({
    required this.appId,
    required this.userId,
    required this.permissionId,
    required this.grantedAt,
    this.requiresStepUpAtNextUse = false,
  });

  final String appId;
  final String userId;
  final String permissionId;
  final DateTime grantedAt;

  /// Tier-2 ops with ``requires_step_up`` flagged in the catalog
  /// flip this to ``true`` after each successful run; the next
  /// invocation has to re-authenticate. Resets to ``true`` whenever
  /// the user revokes + re-grants.
  final bool requiresStepUpAtNextUse;
}

abstract interface class AdminConsentRepository {
  /// True iff the user × app pair holds an active grant for the
  /// permission. The dispatcher calls this on every op dispatch
  /// alongside the cert + VIN-scope check.
  Future<bool> isGranted({
    required String userId,
    required String appId,
    required String permissionId,
  });

  /// Persist the user's install-time decision.
  Future<void> grant(AdminPermissionGrant grant);

  /// Tombstone a grant (don't soft-delete locally — the row is the
  /// permission; absence = no permission).
  Future<void> revoke({
    required String userId,
    required String appId,
    required String permissionId,
  });

  /// Settings-page list — every grant the user has given to [appId].
  Future<List<AdminPermissionGrant>> listForApp({
    required String userId,
    required String appId,
  });
}

/// Phase-4 skeleton. In-memory only — replace with a SharedPreferences
/// or SQLite-backed implementation before any tier-2 op ships to
/// non-internal users. The interface above is the wire contract; the
/// concrete class can change without callers noticing.
class InMemoryAdminConsentRepository implements AdminConsentRepository {
  final Map<String, AdminPermissionGrant> _grants =
      <String, AdminPermissionGrant>{};

  String _key({
    required String userId,
    required String appId,
    required String permissionId,
  }) => '$userId::$appId::$permissionId';

  @override
  Future<bool> isGranted({
    required String userId,
    required String appId,
    required String permissionId,
  }) async {
    return _grants.containsKey(
      _key(userId: userId, appId: appId, permissionId: permissionId),
    );
  }

  @override
  Future<void> grant(AdminPermissionGrant grant) async {
    final key = _key(
      userId: grant.userId,
      appId: grant.appId,
      permissionId: grant.permissionId,
    );
    _grants[key] = grant;
  }

  @override
  Future<void> revoke({
    required String userId,
    required String appId,
    required String permissionId,
  }) async {
    _grants.remove(
      _key(userId: userId, appId: appId, permissionId: permissionId),
    );
  }

  @override
  Future<List<AdminPermissionGrant>> listForApp({
    required String userId,
    required String appId,
  }) async {
    return _grants.values
        .where((g) => g.userId == userId && g.appId == appId)
        .toList(growable: false);
  }
}
