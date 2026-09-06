/// `_admin.exec` dispatcher — the single chokepoint for every
/// privileged mini-app op.
///
/// What this layer does:
///
///   1. Look up the requested template in the cached catalog.
///   2. Decide tier-1 vs tier-2 vs step-up.
///   3. For tier-2: consult the host-stored session cap, the
///      revocation list (fail-closed if stale), and the consent DB.
///   4. Validate params (Phase 7 templates engine).
///   5. Execute the op (this scaffold returns an echo result; real
///      Process.run wiring is the post-9.7 hook for ops that need
///      it; in-Dart ops like ``mqtt_status`` plug in directly).
///   6. Append to the audit chain + bump per-op counter.
///   7. Return ``{success: true, data}`` to the mini-app — the cap
///      envelope NEVER crosses the bridge.
///
/// The mini-app sees only the result. The cap, the revocation
/// state, the audit chain — all owned by the host.
library;

import 'dart:io';

import '../../../platform/observability/observability.dart';
import '../data/consent_repository.dart';
import '../data/db/audit_chain_store.dart'
    show AuditChainStore, StoredAuditEntry;
import '../data/db/revocation_list_store.dart';
import '../data/db/session_cap_store.dart';
import '../data/db/template_catalog_store.dart';
import 'admin_op.dart';
import 'mini_app_gate.dart';

/// Wire shape returned to the mini-app via ``_admin.exec``. Mirrors
/// the public ``AdminOpResponse`` envelope shape so the SDK can
/// JSON-decode without per-op type information.
sealed class AdminExecResult {
  const AdminExecResult();
  Map<String, Object?> toJson();
}

class AdminExecOk extends AdminExecResult {
  const AdminExecOk(this.data);
  final Map<String, Object?> data;

  @override
  Map<String, Object?> toJson() => {'success': true, 'data': data};
}

class AdminExecError extends AdminExecResult {
  const AdminExecError({
    required this.code,
    required this.message,
    this.diagnostics,
  });
  final String code;
  final String message;

  /// Optional structured diagnostic payload — mirrors
  /// `GateDiagnostics.toJson()` when the rejection came from a
  /// host-side gate. Surfaced verbatim under `error.diagnostics` so
  /// mini-app developers can debug from their own console without
  /// access to host logs. `null` for non-gate errors (param
  /// validation, internal error) — keeps the wire shape compact in
  /// those cases.
  final Map<String, Object?>? diagnostics;

  @override
  Map<String, Object?> toJson() => {
    'success': false,
    'error': <String, Object?>{
      'code': code,
      'message': message,
      if (diagnostics != null) 'diagnostics': diagnostics,
    },
  };
}

/// Reason codes the dispatcher emits. Mirror these in any UI that
/// surfaces a failure — keeps copy + logging in lockstep.
class DispatchErrorCode {
  DispatchErrorCode._();
  static const unknownTemplate = 'unknown_template';
  static const userConsentMissing = 'user_consent_missing';
  static const sessionCapMissing = 'session_cap_missing';
  static const sessionCapExpired = 'session_cap_expired';
  static const sessionCapBindingMismatch = 'session_cap_binding_mismatch';
  static const sessionCapDoesNotCoverOp = 'session_cap_does_not_cover_op';
  static const certRevoked = 'cert_revoked';
  static const revocationListStale = 'revocation_list_stale';
  static const stepUpRequired = 'step_up_required';
  static const paramValidationFailed = 'param_validation_failed';
  static const internalError = 'internal_error';
}

/// Strategy port for actually running an op. The dispatcher hands
/// it the rendered shell + the parsed template; an implementation
/// can ``Process.run`` for ADB-shell ops, call native APIs for
/// in-Dart ops (``mqtt_status``), or stub for tests. Keeps the
/// dispatcher independent of the platform-specific bits.
abstract interface class AdminOpExecutor {
  Future<Map<String, Object?>> run({
    required CommandTemplate template,
    required Map<String, Object?> validatedParams,
    required String renderedShell,
  });
}

/// Echo executor — returns the rendered shell as ``data.echo``.
/// Useful for tests and as a default for ops that don't yet have a
/// native implementation. Production wires per-op executors.
class EchoAdminOpExecutor implements AdminOpExecutor {
  const EchoAdminOpExecutor();

  @override
  Future<Map<String, Object?>> run({
    required CommandTemplate template,
    required Map<String, Object?> validatedParams,
    required String renderedShell,
  }) async {
    return {'echo': renderedShell, 'op': template.id};
  }
}

/// Production executor — runs the rendered shell via ``Process.run`` and
/// returns ``{exitCode, stdout, stderr, op}`` to the mini-app. The shell
/// template is the authoritative command (server-vetted, parameter-bound
/// at render time, gated on session-cap presence upstream); the
/// dispatcher has already done param validation + cap verification by
/// the time we reach here.
///
/// Empty ``renderedShell`` short-circuits to an explanatory error so a
/// missing ``shell_template`` (e.g. backend served the public catalog
/// without ``includeShell``) doesn't hang or run ``''``.
///
/// Stdout / stderr are truncated to a fixed cap so a chatty op (think
/// ``logcat.tail``) can't blow past the bridge JSON limits. If a
/// mini-app needs the full payload it should ask for the streaming
/// surface (Phase-11), not this one-shot dispatcher.
class ProcessRunAdminOpExecutor implements AdminOpExecutor {
  const ProcessRunAdminOpExecutor({this.maxOutputBytes = 64 * 1024});

  /// Per-stream output cap. Mini-apps see a ``truncated: true`` flag if
  /// either stream was clipped; full output still lands in adb-side
  /// logs for the dev to inspect.
  final int maxOutputBytes;

  @override
  Future<Map<String, Object?>> run({
    required CommandTemplate template,
    required Map<String, Object?> validatedParams,
    required String renderedShell,
  }) async {
    if (renderedShell.trim().isEmpty) {
      return {
        'op': template.id,
        'error':
            'no shell_template available — template catalog is empty '
            '(backend endpoint not shipped yet).',
      };
    }
    // ``sh -c`` is the one shape that handles every template (pipes,
    // multi-arg, redirections) without per-op argv parsing here. The
    // dispatcher has already gated on session cap + param validation;
    // ``sh -c`` doesn't add new authority, just preserves the shell
    // form the backend rendered.
    final result = await Process.run('sh', ['-c', renderedShell]);
    final stdout = _clip(result.stdout?.toString() ?? '', maxOutputBytes);
    final stderr = _clip(result.stderr?.toString() ?? '', maxOutputBytes);
    return {
      'op': template.id,
      'exitCode': result.exitCode,
      'stdout': stdout.text,
      'stderr': stderr.text,
      if (stdout.truncated || stderr.truncated) 'truncated': true,
    };
  }
}

class _Clipped {
  const _Clipped(this.text, this.truncated);
  final String text;
  final bool truncated;
}

_Clipped _clip(String s, int cap) {
  if (s.length <= cap) return _Clipped(s, false);
  return _Clipped(s.substring(0, cap), true);
}

class AdminMiniAppDispatcher {
  AdminMiniAppDispatcher({
    required this.sessionCaps,
    required this.auditChain,
    required this.templates,
    required this.revocations,
    required this.consents,
    required this.executor,
  });

  final SessionCapStore sessionCaps;
  final AuditChainStore auditChain;
  final TemplateCatalogStore templates;
  final RevocationListStore revocations;
  final AdminConsentRepository consents;
  final AdminOpExecutor executor;

  /// Shared tier-2 gate. Same instance as the family-path consumer
  /// (`bridge/`) reaches for via dependency injection at app
  /// bootstrap — single source of truth for consent / step-up /
  /// revocation / cap binding, so a policy change here lights up
  /// every privileged call site at once.
  late final MiniAppGate _gate = MiniAppGate(
    sessionCaps: sessionCaps,
    revocations: revocations,
    consents: consents,
  );

  /// Entry point invoked by the WebView's ``_admin.exec`` JS
  /// handler. The mini-app passes ``{templateId, params,
  /// idempotencyKey}``; the host fills in the cap from its own
  /// storage.
  ///
  /// [currentSession] carries the runtime context the dispatcher
  /// needs to validate the cap binding (user_id, deviceId, app_id,
  /// cert_hash). The host sources these from its pairing state +
  /// the loaded mini-app's manifest.
  ///
  /// [idempotencyKey] is the SDK-supplied retry token. If non-null
  /// AND a prior audit row exists for (app_id, key), the dispatcher
  /// returns the prior envelope instead of re-executing — this is
  /// the entire point of the SDK sending one on every call. Null is
  /// accepted (no dedup, plain execution) for backward compatibility
  /// and tests.
  Future<AdminExecResult> exec({
    required String templateId,
    Map<String, Object?>? params,
    required AdminSession currentSession,
    String? idempotencyKey,
    DateTime? now,
  }) async {
    // 0. Idempotency replay check. Cheapest gate; runs before any
    // permission work so a dupe retry doesn't re-validate caps,
    // re-acquire shell handles, or re-bump op counters.
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      final prior = await auditChain.findByIdempotencyKey(
        appId: currentSession.appId,
        idempotencyKey: idempotencyKey,
      );
      if (prior != null) {
        return _replayResult(prior);
      }
    }
    // 1. Template lookup (uses cached catalog, keyed by cert hash).
    final template = await templates.lookup(
      certHash: currentSession.certHash,
      templateId: templateId,
    );
    if (template == null) {
      final diagnostics = GateDiagnostics(
        gateName: GateName.miniApp,
        rejectCode: DispatchErrorCode.unknownTemplate,
        rejectAt: MiniAppGateStep.templateLookup,
        appId: currentSession.appId,
        opId: templateId,
      );
      Observability.logGateReject(diagnostics);
      return AdminExecError(
        code: DispatchErrorCode.unknownTemplate,
        message: 'unknown templateId',
        diagnostics: diagnostics.toJson(),
      );
    }

    // 2. Validate params (Phase 7 engine — pure function).
    final Map<String, Object?> validatedParams;
    try {
      validatedParams = validateParams(template, params);
    } on TemplateValidationError catch (e) {
      return AdminExecError(
        code: DispatchErrorCode.paramValidationFailed,
        message: e.toString(),
      );
    }

    // 3. Tier-2 gates: delegated to [MiniAppGate.gateTier2] so the
    // family path runs the same checks. Returns null on pass; an
    // error envelope on reject.
    if (template.tier == AdminOpTier.tier2) {
      final reject = await _gate.gateTier2(
        session: currentSession,
        permissionId: template.permissionId,
        requiresStepUp: template.requiresStepUp,
        op: templateId,
        now: now,
      );
      if (reject != null) return reject;
    }

    // 4. Render the shell + run the op.
    final String rendered;
    try {
      rendered = renderCommand(template, validatedParams);
    } on TemplateRenderError catch (e) {
      // Authoring bug, not a caller issue — log loudly via the
      // ``internalError`` code so on-call gets paged instead of
      // the mini-app developer.
      return AdminExecError(
        code: DispatchErrorCode.internalError,
        message: e.toString(),
      );
    }

    Map<String, Object?> opResult;
    var success = true;
    try {
      opResult = await executor.run(
        template: template,
        validatedParams: validatedParams,
        renderedShell: rendered,
      );
    } catch (e) {
      success = false;
      opResult = {'error': e.toString()};
    }

    // 5. Audit append + counter bump. We do this AFTER the op runs
    // so the audit reflects whether it succeeded; failed ops are
    // recorded too so a forensic upload sees attempted abuse.
    // The idempotency key (if any) is recorded so a future retry
    // hits the replay branch above instead of re-executing.
    await auditChain.append(
      userId: currentSession.userId,
      appId: currentSession.appId,
      op: templateId,
      tier: template.tier == AdminOpTier.tier2 ? 2 : 1,
      success: success,
      payload: {'params': validatedParams, 'result': opResult},
      idempotencyKey: idempotencyKey,
    );
    await auditChain.bumpOpCounter(templateId);

    if (!success) {
      return AdminExecError(
        code: DispatchErrorCode.internalError,
        message: 'op execution failed: ${opResult['error']}',
      );
    }
    return AdminExecOk(opResult);
  }

  /// Reconstruct the [AdminExecResult] envelope from a prior audit
  /// row when an idempotency-key replay hits. The audit row records
  /// both the params and the result, so the original envelope can
  /// be returned byte-equivalent — that's the point of idempotency.
  ///
  /// Failed ops (success=false) become an [AdminExecError] with the
  /// internal-error code, mirroring how the live execution branch
  /// surfaces an executor exception.
  static AdminExecResult _replayResult(StoredAuditEntry prior) {
    final result =
        (prior.payload['result'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    if (prior.success) {
      return AdminExecOk(result);
    }
    return AdminExecError(
      code: DispatchErrorCode.internalError,
      message: 'op execution failed: ${result['error']}',
    );
  }
}

/// Runtime context the host injects into every dispatch. Sourced
/// from the host's pairing state + the active mini-app's manifest.
class AdminSession {
  const AdminSession({
    required this.userId,
    required this.deviceId,
    required this.appId,
    required this.certHash,
    this.bundleSha256,
  });

  final String userId;
  final String deviceId;
  final String appId;
  final String certHash;
  final String? bundleSha256;
}
