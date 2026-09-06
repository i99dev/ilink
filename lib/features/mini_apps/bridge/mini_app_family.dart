/// Bridge-family contract: the shared interface every native-capability
/// surface (display, surface, cursor, gesture, magnify, pkg, boot, …)
/// implements. One pattern, applied N times — adding family N+1 is a
/// new file plus one [BridgeFamilyRegistry.register] call. No edits to
/// [MiniAppViewer], no edits to the dispatcher, no edits to existing
/// families.
///
/// See `lib/features/mini_apps/bridge/bridge_family_registry.dart` for
/// the registry that hosts these.
///
/// Reuses [ParamRule] / [validateParams] from `admin_op.dart` — same
/// schema engine the privileged template dispatcher already runs, so
/// the regex/int/enum semantics are byte-equal across paths.
library;

import '../../admin_mini_apps/domain/admin_dispatcher.dart' show AdminSession;
import '../../admin_mini_apps/domain/admin_op.dart' show ParamRule;
import 'family_event_pusher.dart';

/// Cadence hint the gate uses to choose its execution mode.
///
///  * [standard] — full gate (consent + cap + revocation + audit row)
///    on every call. Default for everything that mutates state once
///    per user gesture.
///  * [hot] — full gate at session-start; subsequent calls bypass
///    cap/consent/revocation re-checks for `T_hot` (5s); audit rows
///    coalesce into one summary row per 1s window. Use ONLY when call
///    rate exceeds ~10 Hz; cursor.move is the canonical case.
///  * [stream] — long-lived subscription. Gate runs at subscribe
///    time; subsequent EventChannel pushes are not gated per-event.
enum HandlerCadence { standard, hot, stream }

/// Input to one [FamilyHandler.execute] invocation. Params are already
/// validated against the handler's [FamilyHandler.paramSchema] by the
/// gate before this struct reaches the handler.
///
/// [eventPusher] gives subscribe-style handlers a way back into the
/// mini-app's JS world without each handler reaching for the WebView
/// controller directly. Standard handlers ignore it. Defaults to a
/// no-op so unit tests that don't care about subscribe paths can
/// build a [BridgeCall] without ceremony.
class BridgeCall {
  const BridgeCall({
    required this.familyId,
    required this.op,
    required this.params,
    required this.session,
    this.idempotencyKey,
    this.eventPusher = const NoopFamilyEventPusher(),
  });

  final String familyId;
  final String op;
  final Map<String, Object?> params;
  final AdminSession session;
  final String? idempotencyKey;
  final FamilyEventPusher eventPusher;
}

/// Caller-visible error from a handler. The gate maps these to the
/// `{success: false, error: {code, message}}` envelope. Any other
/// exception is treated as an internal error and returns the generic
/// `internal_error` code instead.
///
/// Use stable, machine-readable codes: lowercase snake_case, mirrored
/// in the SDK's `*UnavailableError`/permission-denied switch. Don't
/// invent codes per call site — extend the family's own enum and
/// document in the controller.
class BridgeOpError implements Exception {
  const BridgeOpError({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'BridgeOpError($code): $message';
}

/// One operation inside a family. Every handler declares its param
/// schema (so the gate can validate before [execute] runs), its tier
/// posture (does it need a fresh step-up cap?), and its cadence.
abstract interface class FamilyHandler {
  /// Slot rules for this op's params. Empty map = no params accepted.
  /// The gate runs [validateParams] before [execute]; unknown slots
  /// are rejected, defaults are filled in. See
  /// `admin_mini_apps/domain/admin_op.dart` for the rule kinds.
  Map<String, ParamRule> get paramSchema;

  /// True for destructive / state-changing ops that need a per-action
  /// cap on top of the install-time session cap. The gate emits
  /// `step_up_required` when true and the host hasn't attached a
  /// fresh cap.
  bool get requiresStepUp;

  /// Cadence hint — see [HandlerCadence].
  HandlerCadence get cadence;

  /// Execute the op. Params are pre-validated; session is bound to
  /// the calling mini-app + cert + VIN. Return the success envelope
  /// `data` payload. Throw [BridgeOpError] for caller-visible
  /// failures; any other exception becomes an `internal_error`
  /// envelope.
  Future<Map<String, Object?>> execute(BridgeCall call);
}

/// One named family of bridge handlers. Implementations are pure
/// Dart — platform-specific work lives in a sibling
/// `*NativeBridge` (one [MethodChannel] / [EventChannel] per family),
/// itself a thin wrapper around the only file that imports
/// `dart:ui` / `package:flutter/services.dart` for that family.
///
/// Cardinal rule (project memory `feedback_engineering_axes`): keep
/// platform imports isolated. A family's `*Family.dart` MUST NOT
/// import `dart:io`, `package:flutter/services.dart`, or any other
/// platform-tied package directly. Tests depend on this.
///
/// This is a plain `abstract class` (not `abstract interface class`)
/// so concrete families can `extends MiniAppFamily` and inherit the
/// default [permissionIdFor], [ensureInitialized], [dispose]. The
/// only required overrides are [familyId], [permissionIds], and
/// [handlers].
abstract class MiniAppFamily {
  /// Stable identifier. Used as the prefix in JS handler names —
  /// `<familyId>.<op>` (e.g. `display.list`).
  String get familyId;

  /// Permissions this family draws on. The gate looks up the active
  /// op's handler-specific permission via [permissionIdFor]; this
  /// set is the union, used for the capabilities handshake.
  Set<String> get permissionIds;

  /// Per-op permission selector. Lets one family route different ops
  /// to different perms (e.g. `pkg.list` → `pkg.read`,
  /// `pkg.launch` → `pkg.launch`). Default impl assumes one
  /// permission applies to every op — override when a family is
  /// split across tiers.
  String permissionIdFor(String op) {
    if (permissionIds.length != 1) {
      throw StateError(
        'family $familyId has ${permissionIds.length} permissions but '
        'permissionIdFor($op) was not overridden — implementer must '
        'choose per op',
      );
    }
    return permissionIds.first;
  }

  /// Map of op-name → handler. The keys appear in JS as the suffix
  /// after the family id.
  Map<String, FamilyHandler> get handlers;

  /// Whether this family is exposed on a secondary surface (a
  /// [Presentation]-backed WebView opened by `surface.create`).
  /// Default `false`: only `getContext` and read-only data families
  /// flip this on. Privileged families (cursor,
  /// gesture, magnify, pkg.*write*, boot) MUST keep it false to
  /// prevent recursive privilege from a child surface.
  bool get secondaryAllowed => false;

  /// Per-op override for [secondaryAllowed]. Lets one family expose
  /// its read handlers on a secondary surface while keeping its
  /// write handlers IVI-only (e.g. `pkg.list` is fine to call from a
  /// cluster widget; `pkg.launch` would be an escalation gadget).
  /// Default: defer to the family-wide [secondaryAllowed]. Override
  /// only when a family is split across read/write semantics.
  bool secondaryAllowedFor(String op) => secondaryAllowed;

  /// Lazy native init. Called by the registry the first time any of
  /// this family's handlers fires; gives the family a chance to
  /// open its [MethodChannel] without paying the cost on host
  /// boot. Default: no-op.
  Future<void> ensureInitialized() async {}

  /// Tear-down hook for tests / hot-reload. Default: no-op.
  Future<void> dispose() async {}
}
