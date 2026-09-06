/// Single chokepoint for every family bridge call.
///
/// Lifecycle, in order:
///   1. Family lookup (registry)
///   2. Op lookup (family.handlers)
///   3. Local scope + optional owner confirmation, then idempotency replay
///   4. Param validation (handler.paramSchema, reuses [validateParams])
///   5. handler.execute(BridgeCall(...))
///   6. Audit append
///   7. Returns the [AdminExecResult] envelope verbatim — same wire
///      shape the legacy `_admin.exec` path uses, so the SDK
///      decoder is identical on both sides.
///
/// One instance per host. Constructed at app bootstrap, injected
/// into the WebView wiring.
///
/// Each operation requires a local owner grant bound to the installed archive.
library;

import '../../../platform/observability/observability.dart';
import '../../admin_mini_apps/data/db/audit_chain_store.dart';
import '../../admin_mini_apps/domain/admin_dispatcher.dart'
    show
        AdminExecError,
        AdminExecOk,
        AdminExecResult,
        AdminSession,
        DispatchErrorCode;
import '../../admin_mini_apps/domain/admin_op.dart'
    show TemplateValidationError, ParamRule;
import 'bridge_family_registry.dart';
import 'family_event_pusher.dart';
import 'mini_app_family.dart';

/// The family-call dispatcher. Owns an audit-write pipeline and
/// delegates to the registry for family/op lookup.
///
/// Reuses, does not rebuild:
///   * [validateParams] / [ParamRule] from `admin_op.dart` — same
///     schema engine the template path uses.
///   * [AuditChainStore] — same audit chain the template path writes
///     to. Family ops appear with `op = '<familyId>.<op>'` so a
///     forensic SELECT mixes both paths cleanly.
class FamilyExecutor {
  FamilyExecutor({
    required this.registry,
    required this.auditChain,
    this.authorize,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BridgeFamilyRegistry registry;
  final AuditChainStore auditChain;
  final Future<bool> Function(AdminSession session, String scope)? authorize;
  // ignore: unused_field
  final DateTime Function() _now;

  /// Entry point invoked per JS handler call. The viewer wires
  /// `<familyId>.<op>` handler names to `execute(familyId, op, ...)`.
  ///
  /// [eventPusher] is the per-call channel back into the calling
  /// WebView's JS world. Subscribe-style handlers carry it; standard
  /// handlers ignore it. Defaults to a no-op pusher so non-viewer
  /// callers (tests, the secondary-surface dispatcher when forwarding
  /// read-only ops) don't have to thread one through.
  Future<AdminExecResult> execute({
    required String familyId,
    required String op,
    required Map<String, Object?> args,
    required AdminSession session,
    String? idempotencyKey,
    bool ownerConfirmed = false,
    DateTime? now,
    FamilyEventPusher eventPusher = const NoopFamilyEventPusher(),
  }) async {
    // 1. Family lookup.
    final family = registry.lookup(familyId);
    if (family == null) {
      return AdminExecError(
        code: DispatchErrorCode.unknownTemplate,
        message: 'unknown family: $familyId',
      );
    }

    // 2. Op lookup.
    final handler = family.handlers[op];
    if (handler == null) {
      return AdminExecError(
        code: DispatchErrorCode.unknownTemplate,
        message: 'unknown op: $familyId.$op',
      );
    }

    final scope = family.permissionIdFor(op);
    if (authorize == null || !await authorize!(session, scope)) {
      return AdminExecError(
        code: 'permission_denied',
        message: 'Local owner has not granted $scope for this installed bundle',
      );
    }

    if (handler.requiresStepUp && !ownerConfirmed) {
      return const AdminExecError(
        code: 'permission_denied',
        message: 'This operation requires local confirmation',
      );
    }

    // Authorize before replay so revoked scopes cannot recover old results.
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      final prior = await auditChain.findByIdempotencyKey(
        appId: session.appId,
        idempotencyKey: idempotencyKey,
      );
      if (prior != null &&
          prior.op == '$familyId.$op' &&
          prior.payload['bundleSha256'] == session.bundleSha256) {
        return _replayResult(prior);
      }
      if (prior != null) {
        return const AdminExecError(
          code: 'idempotency_conflict',
          message: 'This request key belongs to another operation or bundle',
        );
      }
    }

    // 3. Param validation. Reuses [validateParams] — same engine,
    // same error codes.
    final Map<String, Object?> validatedParams;
    try {
      validatedParams = _validateAgainstSchema(handler.paramSchema, args);
    } on TemplateValidationError catch (e) {
      return AdminExecError(
        code: DispatchErrorCode.paramValidationFailed,
        message: e.toString(),
      );
    }

    // 4. Execute the handler.
    final call = BridgeCall(
      familyId: familyId,
      op: op,
      params: validatedParams,
      session: session,
      idempotencyKey: idempotencyKey,
      eventPusher: eventPusher,
    );

    Map<String, Object?> data;
    AdminExecResult envelope;
    try {
      data = await handler.execute(call);
      envelope = AdminExecOk(data);
    } on BridgeOpError catch (e) {
      // Family-level rejection. The Kotlin side returns codes like
      // `role:requires_cluster_op`, `role:expected_cluster_got_passenger`,
      // `role:display_not_found`, plus the canonical
      // `permission_denied`. Classify them into shared
      // [GateDiagnostics] so the Sentry log + bridge envelope carry
      // the same structured payload that mini-app developers can
      // read from their own console.
      final diag = _diagnoseBridgeError(
        familyId: familyId,
        op: op,
        appId: session.appId,
        code: e.code,
        message: e.message,
      );
      if (diag != null) Observability.logGateReject(diag);
      envelope = AdminExecError(
        code: e.code,
        message: e.message,
        diagnostics: diag?.toJson(),
      );
    } catch (e, st) {
      // Unknown failure inside ``handler.execute`` — typically a
      // ``PlatformException`` thrown by Kotlin (missing permission on
      // the native side, NPE in a system service, etc.) or a Dart
      // bug. The mini-app gets a generic envelope; we ALSO record it
      // via Observability so ops can see the unhandled path in Sentry
      // — without this hook, these failures silently terminate the
      // family call and never surface beyond the WebView console.
      // The hint encodes the family + op so triage doesn't need to
      // grep call sites.
      // ignore: unawaited_futures
      Observability.recordError(e, st, hint: 'family_executor:$familyId.$op');
      envelope = AdminExecError(
        code: DispatchErrorCode.internalError,
        message: 'family op failed: $e',
      );
    }

    // 5. Audit append.
    final success = envelope is AdminExecOk;
    await auditChain.append(
      userId: session.userId,
      appId: session.appId,
      op: '$familyId.$op',
      tier: 1,
      success: success,
      payload: {
        'bundleSha256': session.bundleSha256,
        'params': validatedParams,
        'result': switch (envelope) {
          AdminExecOk(:final data) => data,
          AdminExecError(:final message) => {'error': message},
        },
        'cadence': handler.cadence.name,
      },
      idempotencyKey: idempotencyKey,
    );
    await auditChain.bumpOpCounter('$familyId.$op');

    return envelope;
  }

  /// Build the family list shipped to the mini-app via the
  /// capabilities handshake. Mini-apps `client.has(scope)` against
  /// this set.
  Iterable<String> familyIdsForCapabilities() => registry.familyIds;

  // ── internals ────────────────────────────────────────────────────

  /// Run the same validateParams logic the template engine uses, but
  /// over a raw [paramSchema] map (no enclosing CommandTemplate).
  /// Pure function over the slot rules — defaults filled, unknowns
  /// rejected, type-mismatch raised.
  Map<String, Object?> _validateAgainstSchema(
    Map<String, ParamRule> schema,
    Map<String, Object?>? input,
  ) {
    final raw = Map<String, Object?>.from(input ?? const {});
    final extras = raw.keys.toSet().difference(schema.keys.toSet());
    if (extras.isNotEmpty) {
      throw TemplateValidationError(
        slot: extras.first,
        message: 'unknown slots: $extras',
      );
    }
    final out = <String, Object?>{};
    for (final entry in schema.entries) {
      final slot = entry.key;
      final rule = entry.value;
      if (!raw.containsKey(slot)) {
        // Defaults are rule-specific; only IntParamRule carries one.
        // Mirror admin_op.validateParams' shape so behaviour matches.
        final coerced = _maybeDefault(rule);
        if (coerced != null) {
          out[slot] = coerced;
          continue;
        }
        throw TemplateValidationError(
          slot: slot,
          message: 'required param missing',
        );
      }
      out[slot] = rule.validate(slot, raw[slot]);
    }
    return out;
  }

  /// Returns the default value for a [ParamRule] if it has one,
  /// else null. Mirrors the carve-out in admin_op.validateParams.
  Object? _maybeDefault(ParamRule rule) {
    final json = rule.toMiniAppJson();
    // Any rule that exposes a `default` key in its JSON shape can
    // back-fill a missing slot. IntParamRule has always supported
    // this; RegexParamRule grew the same field in Phase C so
    // optional regex slots (e.g. `route` in boot.set) don't have to
    // be hand-sent by every SDK call site.
    if (json.containsKey('default')) {
      return json['default'];
    }
    return null;
  }

  AdminExecResult _replayResult(StoredAuditEntry prior) {
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

  /// Classify a [BridgeOpError] into a [GateDiagnostics] when the
  /// code matches a known gate pattern. Returns null for non-gate
  /// errors (handler-internal failures, bad-request validation done
  /// inside the handler) so we don't pollute the gate-reject Sentry
  /// stream with unrelated noise.
  ///
  /// Recognised patterns — kept in lockstep with the Kotlin side
  /// emit codes (`PackagePlatformPlugin.checkDisplayRole`):
  ///   * `permission_denied` → CarReadGate / family-permission gate
  ///   * `role:expected_cluster_got_<role>` →
  ///     CarWriteGate role mismatch
  ///   * `role:requires_cluster_op` → caller used standard launch on
  ///     a cluster id; should call `pkg.launch_cluster`
  ///   * `role:display_not_found` → display id doesn't exist
  ///   * `role:unknown` → display has no recognized role
  static GateDiagnostics? _diagnoseBridgeError({
    required String familyId,
    required String op,
    required String appId,
    required String code,
    required String message,
  }) {
    final opId = '$familyId.$op';
    if (code == 'permission_denied') {
      // CarReadGate / family-permission denial. The handler embeds
      // the missing permission id in the message verbatim — we don't
      // re-derive it here to keep this classifier pure (no registry
      // access on a hot path).
      return GateDiagnostics(
        gateName: GateName.carRead,
        rejectCode: code,
        appId: appId,
        opId: opId,
        familyId: familyId,
      );
    }
    if (code.startsWith('role:')) {
      // CarWriteGate / display-control gate. The colon-separated
      // suffix encodes the specific reason; preserved as
      // `rejectCode` so triagers can filter by exact value, while
      // `rejectAt` carries the canonical reason taxonomy.
      final reason = switch (code) {
        'role:requires_cluster_op' => CarWriteGateReason.roleMismatch,
        'role:display_not_found' => CarWriteGateReason.displayNotFound,
        _ when code.startsWith('role:expected_cluster_got') =>
          CarWriteGateReason.roleMismatch,
        _ when code.startsWith('role:unknown') =>
          CarWriteGateReason.displayNotFound,
        _ => CarWriteGateReason.permissionMissing,
      };
      // Try to extract the displayId from the message ("...
      // displayId=N"). Best-effort — no regex compile on every call;
      // a simple scan suffices for the controlled message format.
      int? displayId;
      const marker = 'displayId=';
      final idx = message.indexOf(marker);
      if (idx >= 0) {
        final tail = message.substring(idx + marker.length);
        final end = tail.indexOf(RegExp(r'[^\d]'));
        final num = end == -1 ? tail : tail.substring(0, end);
        displayId = int.tryParse(num);
      }
      // The `expected_cluster_got_<role>` shape carries the actual
      // resolved role inline — extract it.
      String? actualRole;
      const got = 'role:expected_cluster_got_';
      if (code.startsWith(got)) {
        actualRole = code.substring(got.length).split(' ').first;
      }
      return GateDiagnostics(
        gateName: GateName.carWrite,
        rejectCode: code,
        rejectAt: reason,
        appId: appId,
        opId: opId,
        familyId: familyId,
        targetDisplayId: displayId,
        targetRole: actualRole,
      );
    }
    return null;
  }
}
