/// Single source of truth for the structured diagnostic payload that
/// every host-side gate (MiniAppGate, CarReadGate, CarWriteGate)
/// emits when it rejects a call.
///
/// Two consumers, one shape:
///
///   * **Sentry Logs** — [Observability.logGateReject] reads this and
///     ships it as a `warn`-level row with the per-trim tags already
///     on the scope. Triagers filter "show me every cluster reject
///     on Leopard 5 today" with one query.
///   * **Bridge error envelope** — the same map is attached to the
///     `error.diagnostics` field that `family_executor.dart` and
///     `mini_app_gate.dart` return to the WebView. Mini-app
///     developers see the full reason in their own console without
///     needing access to Sentry.
///
/// Why a value class instead of a free-floating map: keeps the field
/// names DRY (a typo in one gate would silently break the Sentry
/// query for every other gate), makes the wire shape obvious to
/// downstream consumers (SDK types can mirror it 1:1), and keeps the
/// list of acceptable values for `gateName` / `rejectReason` closed
/// to the constants below.
library;

import 'package:flutter/foundation.dart';

@immutable
class GateDiagnostics {
  const GateDiagnostics({
    required this.gateName,
    required this.rejectCode,
    this.rejectAt,
    this.appId,
    this.opId,
    this.familyId,
    this.declaredPerms,
    this.neededPerms,
    this.deniedKeys,
    this.targetDisplayId,
    this.targetRole,
  });

  /// Which gate decided. Closed enum: `mini_app_gate` /
  /// `car_read_gate` / `car_write_gate`. Wrapped in
  /// [GateName] constants below; callers should use those.
  final String gateName;

  /// The error envelope's `code` — `permission_denied` /
  /// `consent_required` / `cap_invalid` / `revoked` /
  /// `unknown_template` / `role_mismatch` / etc.
  /// Same value as `error.code` in the bridge envelope so a
  /// triager can join logs and bridge replies.
  final String rejectCode;

  /// Sub-step within the gate that fired the reject. For
  /// MiniAppGate's tier-2 path: `template_lookup` / `consent` /
  /// `cap` / `revocation`. Null when the gate has no internal
  /// branching.
  final String? rejectAt;

  /// Calling mini-app id (e.g. `pkg-launcher`). Public catalog
  /// name — never PII, never the cert hash.
  final String? appId;

  /// Op identifier the gate evaluated. For MiniAppGate the
  /// `templateId`; for read/write gates the `family.op` token.
  final String? opId;

  /// Family the gate is enforcing — `car.status` / `climate` /
  /// `vehicle.diagnostics` / `surface` / `cursor` / `gesture`.
  /// Distinct from [opId] so bug reports filtered to a family
  /// can find every rejection regardless of op.
  final String? familyId;

  /// Permissions the manifest *did* declare. The pair with
  /// [neededPerms] is what tells a developer they need to
  /// re-publish with one more entry.
  final List<String>? declaredPerms;

  /// Permissions the gate actually needed. Empty when the gate
  /// rejected for a non-permission reason (e.g. revocation).
  final List<String>? neededPerms;

  /// CarReadGate filtered keys — wire keys (`gearPosition`,
  /// `aqi`, etc.) that the gate stripped from the response.
  /// Lets developers see exactly which fields they're missing.
  final List<String>? deniedKeys;

  /// Display targeted by a CarWriteGate decision. Null on
  /// non-display gates.
  final int? targetDisplayId;

  /// Role of [targetDisplayId] when resolved — `cluster` /
  /// `passenger` / `ivi` / `unknown`. Pairs with `role_mismatch`
  /// rejections to explain "you asked for a passenger op on a
  /// cluster display."
  final String? targetRole;

  /// Wire shape for the bridge error envelope. Keeps null fields
  /// out so the JSON stays compact for the WebView.
  Map<String, Object?> toJson() => <String, Object?>{
    'gate': gateName,
    'rejectCode': rejectCode,
    if (rejectAt != null) 'rejectAt': rejectAt,
    if (appId != null) 'appId': appId,
    if (opId != null) 'opId': opId,
    if (familyId != null) 'familyId': familyId,
    if (declaredPerms != null) 'declaredPerms': declaredPerms,
    if (neededPerms != null) 'neededPerms': neededPerms,
    if (deniedKeys != null) 'deniedKeys': deniedKeys,
    if (targetDisplayId != null) 'targetDisplayId': targetDisplayId,
    if (targetRole != null) 'targetRole': targetRole,
  };
}

/// Closed set of gate names. Callers use these instead of literal
/// strings so a typo can't silently break a Sentry filter.
abstract final class GateName {
  static const miniApp = 'mini_app_gate';
  static const carRead = 'car_read_gate';
  static const carWrite = 'car_write_gate';
}

/// Closed set of MiniAppGate sub-steps — keeps the Sentry filter
/// surface stable. Adding a new step requires a code change here +
/// in MiniAppGate.gateTier2.
abstract final class MiniAppGateStep {
  static const templateLookup = 'template_lookup';
  static const consent = 'consent';
  static const cap = 'cap';
  static const revocation = 'revocation';
}

/// Closed set of CarWriteGate reject reasons. `permission_missing` /
/// `role_mismatch` / `display_not_found` cover what the role
/// classifier and manifest gate together can produce.
abstract final class CarWriteGateReason {
  static const permissionMissing = 'permission_missing';
  static const roleMismatch = 'role_mismatch';
  static const displayNotFound = 'display_not_found';
}
