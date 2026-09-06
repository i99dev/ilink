/// Retained authority checks for legacy template-bound privileged operations.
/// AdminMiniAppDispatcher reads cached consent, revocation data and signed
/// session capabilities through this gate. There is no issuer or renewal
/// service in the standalone app: missing, stale, expired or mismatched
/// authority is rejected, and required step-up is unavailable here.
///
/// Current local family operations use FamilyExecutor's bundle-hash-bound
/// scope authorization and explicit local confirmation. They do not call this
/// gate or gain authority from its compatibility requireBinding=false mode.
library;

import '../../../platform/observability/observability.dart';
import '../data/consent_repository.dart';
import '../data/db/revocation_list_store.dart';
import '../data/db/session_cap_store.dart';
import 'admin_dispatcher.dart'
    show AdminExecError, AdminSession, DispatchErrorCode;

/// Stores the gate consults. Mirrors the subset of fields
/// [AdminMiniAppDispatcher] already holds, so a dispatcher can
/// build a gate from its own deps without duplicating wiring.
class MiniAppGate {
  const MiniAppGate({
    required this.sessionCaps,
    required this.revocations,
    required this.consents,
  });

  final SessionCapStore sessionCaps;
  final RevocationListStore revocations;
  final AdminConsentRepository consents;

  /// Returns null when the cached authority permits dispatch, otherwise an
  /// AdminExecError for the caller to return and record in its local audit.
  ///
  /// Consent is always required. With requireBinding=true (the production
  /// legacy dispatcher), this rejects required step-up, stale revocation data,
  /// revoked certificates, and missing/expired capabilities. The capability
  /// must match user, device, app and certificate and explicitly cover the op.
  /// These stores are read locally; this method cannot fetch or renew authority.
  ///
  /// requireBinding=false is retained compatibility behavior tested separately:
  /// it checks consent only and skips issuer-bound checks and step-up rejection.
  /// It does not validate an installed bundle or provide per-action confirmation
  /// and is not the current family-operation permission boundary.
  Future<AdminExecError?> gateTier2({
    required AdminSession session,
    required String permissionId,
    required bool requiresStepUp,
    required String op,
    bool requireBinding = true,
    DateTime? now,
  }) async {
    // 1. Consent.
    final granted = await consents.isGranted(
      userId: session.userId,
      appId: session.appId,
      permissionId: permissionId,
    );
    if (!granted) {
      return _reject(
        session: session,
        op: op,
        permissionId: permissionId,
        rejectAt: MiniAppGateStep.consent,
        code: DispatchErrorCode.userConsentMissing,
        message: 'user has not granted this permission',
      );
    }

    // Legacy step-up cannot be renewed or satisfied by this local gate.
    // Reject it; no backend fetch or automatic retry is available. Current
    // FamilyExecutor operations enforce local confirmation independently.
    if (requiresStepUp && requireBinding) {
      return _reject(
        session: session,
        op: op,
        permissionId: permissionId,
        rejectAt: MiniAppGateStep.consent,
        code: DispatchErrorCode.stepUpRequired,
        message: 'step-up auth required for this op',
      );
    }

    // Legacy issuer-bound capabilities retain their freshness checks.
    // Local manifest-consent operations have no external certificate issuer.
    if (requireBinding && await revocations.isStale(now: now)) {
      return _reject(
        session: session,
        op: op,
        permissionId: permissionId,
        rejectAt: MiniAppGateStep.revocation,
        code: DispatchErrorCode.revocationListStale,
        message: 'revocation list stale; cannot dispatch tier-2',
      );
    }

    // 4-5 only apply to the legacy `_admin.exec` / `cmdExec.*` path —
    // see [requireBinding] doc above.
    if (requireBinding) {
      // 4. Cert revoked?
      if (await revocations.isRevoked(session.certHash)) {
        return _reject(
          session: session,
          op: op,
          permissionId: permissionId,
          rejectAt: MiniAppGateStep.revocation,
          code: DispatchErrorCode.certRevoked,
          message: 'developer cert is revoked',
        );
      }

      // 5. Session cap.
      final cap = await sessionCaps.get(
        userId: session.userId,
        deviceId: session.deviceId,
        appId: session.appId,
      );
      if (cap == null) {
        return _reject(
          session: session,
          op: op,
          permissionId: permissionId,
          rejectAt: MiniAppGateStep.cap,
          code: DispatchErrorCode.sessionCapMissing,
          message: 'no session cap; install the app first',
        );
      }
      if (cap.isExpired(now: now)) {
        return _reject(
          session: session,
          op: op,
          permissionId: permissionId,
          rejectAt: MiniAppGateStep.cap,
          code: DispatchErrorCode.sessionCapExpired,
          message: 'session cap expired; refresh required',
        );
      }
      // The four binding fields MUST match the running session. Leaked
      // cap on a different (user, deviceId, app, cert) returns reject — not
      // fallback. Critical security boundary.
      if (cap.userId != session.userId ||
          cap.deviceId != session.deviceId ||
          cap.appId != session.appId ||
          cap.certHash != session.certHash) {
        return _reject(
          session: session,
          op: op,
          permissionId: permissionId,
          rejectAt: MiniAppGateStep.cap,
          code: DispatchErrorCode.sessionCapBindingMismatch,
          message: 'session cap does not match current session',
        );
      }
      if (!cap.opsAllowed.contains(op)) {
        return _reject(
          session: session,
          op: op,
          permissionId: permissionId,
          rejectAt: MiniAppGateStep.cap,
          code: DispatchErrorCode.sessionCapDoesNotCoverOp,
          message: 'op not in session cap ops_allowed',
        );
      }
    }

    return null;
  }

  /// Attach structured rejection diagnostics to the returned error.
  /// Observability is a local compatibility facade with no remote transport.
  AdminExecError _reject({
    required AdminSession session,
    required String op,
    required String permissionId,
    required String rejectAt,
    required String code,
    required String message,
  }) {
    final diagnostics = GateDiagnostics(
      gateName: GateName.miniApp,
      rejectCode: code,
      rejectAt: rejectAt,
      appId: session.appId,
      opId: op,
      neededPerms: <String>[permissionId],
    );
    Observability.logGateReject(diagnostics);
    return AdminExecError(
      code: code,
      message: message,
      diagnostics: diagnostics.toJson(),
    );
  }
}
