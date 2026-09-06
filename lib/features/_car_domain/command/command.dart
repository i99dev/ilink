import 'package:flutter/material.dart';

import '../safety/rate_limiter.dart';

/// Category the command belongs to — drives grouping in UI surfaces
/// (quick actions grid, feature rail, tunnel debug). `radio` and `apps` are
/// the non-hardware categories: `radio` drives the in-app player, `apps`
/// launches other Android apps via the shell bridge (`am start`). Both live
/// in the same registry so voice dispatch routes to them without branching.
enum CommandCategory {
  door,
  climate,
  comfort,
  light,
  window,
  status,
  raw,
  radio,
  apps,
}

/// Safety classification of a command — the FIRST-CLASS signal a
/// background/automation dispatch (the workflow engine) uses to decide
/// its independent stationary gate + whether to require explicit
/// confirmation.
///
/// **Never derive this from [CarCommand.reversible].** `reversible`
/// means "safe to predict/undo for voice" and is `true` for
/// `door.unlock` and every window — the OPPOSITE of "safe to fire
/// unattended while moving". A human tap is a person choosing to act
/// now; a background trigger firing the same action has no
/// human-present backstop, so the engine gates on this field instead.
///
/// Mirrors `SecurityClass` in `ilink-sdk` `types/workflow.ts` and the
/// `SECURITY_CLASSES` wire enum surfaced by `workflow.catalog`.
enum SecurityClass {
  /// Comfort / convenience — climate, lights, media, seat heat/vent.
  /// Safe to fire unattended (still subject to rate limits).
  none,

  /// Physically unsafe if actuated while moving or unattended —
  /// windows, sunroof, trunk, hood, (future) seat motion. The engine
  /// blocks these for a moving car by default and may require
  /// confirmation for a background trigger.
  safety,

  /// Security-sensitive — door unlock. A background/automation trigger
  /// must carry explicit user confirmation before the engine runs it.
  security,
}

/// Result of a [CarCommand.resolve] call — the actual daemon action id
/// to dispatch and the (possibly transformed) args to pass.
typedef ResolvedAction = ({String actionId, Map<String, dynamic> args});

/// Optional resolver for parameterized commands whose id (`comfort.massage`)
/// doesn't match a daemon action_id directly. Takes the user-supplied
/// args and returns the actual `(actionId, args)` to send to the bridge.
/// When null, the router dispatches `cmd.id` with `args` unchanged.
typedef CommandResolve = ResolvedAction Function(Map<String, dynamic> args);

/// Single user-addressable command, keyed by dotted id
/// (e.g. `door.lock`, `comfort.massage`). Dispatch is by id — the
/// router calls `bridge.runAction(cmd.resolve(args).actionId, …)` and
/// the daemon looks the id up in the encrypted action table. No
/// per-domain controller indirection.
class CarCommand {
  const CarCommand({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    required this.category,
    this.resolve,
    this.params = const {},
    this.paramDefaults = const {},
    this.requiresStationary = false,
    this.securityClass = SecurityClass.none,
    this.rateClass,
    this.voiceGroup,
    this.voiceIdTemplate,
    this.voiceGroupParams,
    this.voiceGroupParamDefaults = const {},
    this.voiceDescription,
    this.voiceHidden = false,
    this.reversible = false,
  }) : assert(
         (voiceGroup == null) ==
             (voiceIdTemplate == null && voiceGroupParams == null),
         'voiceGroup must be set alongside voiceIdTemplate and '
         'voiceGroupParams — or all three must be null. '
         'voiceDescription is independent and may be set on any command.',
       );

  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final CommandCategory category;

  /// Expected param schema — UI uses this to know what to collect
  /// (e.g. massage needs seat + field + value). Keys map to param names.
  final Map<String, String> params;

  /// Defaults applied when the voice model omits a param. Any key
  /// listed here is exposed to the LLM as **optional** — dropped from
  /// `required[]` and stamped with `default:` in the generated JSON
  /// schema — and the value is also passed through to the exec
  /// handler (which usually has its own `?? fallback` already; the
  /// schema default is what makes the LLM willing to omit the arg).
  ///
  /// Use this to remove ergonomic friction: without a default, "turn
  /// on massage" forces the LLM to invent a value (or refuse), but
  /// with `paramDefaults: {value: 1}` the model can call the tool
  /// with no args and get the sensible default.
  ///
  /// Empty (the default) preserves the original behaviour where every
  /// declared param is required.
  final Map<String, Object> paramDefaults;

  /// Optional id+args transform for parameterized commands. Null when
  /// `cmd.id` is itself the daemon action_id (the common case).
  final CommandResolve? resolve;

  /// When true, [CarCommandRouter] refuses to execute this command while
  /// the vehicle is moving (speed > 5 km/h). Opt-in only — defaults to
  /// false because the vast majority of commands (lock doors, set temp,
  /// turn on fog lights) are safe at speed. Flag only the clearly-unsafe
  /// ones (unlock doors, open trunk, drop windows, tilt sunroof).
  final bool requiresStationary;

  /// Safety classification used by background/automation dispatch. See
  /// [SecurityClass] — derived independently of [reversible]. Defaults
  /// to [SecurityClass.none] (comfort/convenience); the door/window/
  /// sunroof/trunk/hood domains tag `safety`/`security` explicitly.
  final SecurityClass securityClass;

  /// Rate-limiter bucket this command falls into. `null` means the router
  /// falls back to [RateLimiter.classify] on the command id (prefix
  /// matching). Declare explicitly when the prefix heuristic would be
  /// wrong — e.g. an actuator command that happens to live under the
  /// `climate.` namespace would otherwise be limited as climate.
  final RateClass? rateClass;

  // ── Voice-tool grouping (optional) ───────────────────────────────────

  /// Optional name of a *manifest-level* group this command belongs to.
  /// Every command sharing a [voiceGroup] collapses into a single entry in
  /// the OpenAI tools manifest — so 18 `window.*` commands surface as one
  /// `window_control` tool, not 18. Null = expose as its own tool (the
  /// default, and what every pre-grouping command did).
  ///
  /// All members of a group must agree on [voiceIdTemplate],
  /// [voiceGroupParams], and [voiceDescription]; the manifest builder uses
  /// the first member's values and the consistency is enforced by a
  /// dedicated test (`voice_group_consistency_test.dart`).
  final String? voiceGroup;

  /// Template string used to rebuild the registry id from the group tool's
  /// args at dispatch time, e.g. `window.{window}.{action}`. Placeholders
  /// must name keys present in [voiceGroupParams]. Null iff [voiceGroup] is
  /// null.
  final String? voiceIdTemplate;

  /// Schema hints (same shape as [params]) describing the *group tool's*
  /// args — which are typically a superset of any individual member's
  /// params because the template placeholders become extra required args.
  final Map<String, String>? voiceGroupParams;

  /// Defaults applied when the voice model omits a param on the
  /// *group* tool — same semantics as [paramDefaults] but scoped to
  /// [voiceGroupParams].
  final Map<String, Object> voiceGroupParamDefaults;

  /// Human-readable description shown to the voice model as the tool
  /// description. Should include a couple of utterance examples — the
  /// model leans on the description to choose between tools. For grouped
  /// commands, all members should carry the same voiceDescription; for
  /// flat commands, setting this overrides the default "label + category"
  /// auto-generated description.
  final String? voiceDescription;

  /// When true, this command is omitted from the voice tools manifest
  /// entirely. Still reachable via the WebSocket tunnel and UI tiles. Use
  /// for UI-only quick-action variants (e.g. fixed `light.head.on` /
  /// `.off` tiles kept around because the quick-actions grid expects them,
  /// even though voice uses the parameterized `light.head(on)` instead).
  final bool voiceHidden;

  /// True when the action is safely reversible by the user within a
  /// short window — climate setpoint changes, light toggles, station
  /// switches. The voice predictive executor fires reversible
  /// + high-confidence calls in parallel with TTS confirmation,
  /// shaving ~150–300ms off perceived latency.
  ///
  /// Default false (conservative). Mark each command explicitly:
  ///   - reversible: yes  → climate.setTemp, lights.toggle,
  ///                         radio.playByName, door.lock, window.set
  ///   - reversible: no   → door.unlock (security), navigate-and-start
  /// The plan's table lists the canonical assignments; new commands
  /// must justify a `true` value (default to false on review).
  final bool reversible;

  /// Returns a clone of this command with selected fields replaced.
  /// Used by domain command lists to bulk-stamp [reversible] across
  /// every entry without re-typing every constructor field.
  CarCommand withReversible(bool value) => CarCommand(
    id: id,
    label: label,
    icon: icon,
    color: color,
    category: category,
    resolve: resolve,
    params: params,
    paramDefaults: paramDefaults,
    requiresStationary: requiresStationary,
    securityClass: securityClass,
    rateClass: rateClass,
    voiceGroup: voiceGroup,
    voiceIdTemplate: voiceIdTemplate,
    voiceGroupParams: voiceGroupParams,
    voiceGroupParamDefaults: voiceGroupParamDefaults,
    voiceDescription: voiceDescription,
    voiceHidden: voiceHidden,
    reversible: value,
  );

  /// Returns a clone with [securityClass] replaced. Lets a domain list
  /// bulk-stamp a class (e.g. every window/sunroof entry → `safety`)
  /// without re-typing every constructor field.
  CarCommand withSecurityClass(SecurityClass value) => CarCommand(
    id: id,
    label: label,
    icon: icon,
    color: color,
    category: category,
    resolve: resolve,
    params: params,
    paramDefaults: paramDefaults,
    requiresStationary: requiresStationary,
    securityClass: value,
    rateClass: rateClass,
    voiceGroup: voiceGroup,
    voiceIdTemplate: voiceIdTemplate,
    voiceGroupParams: voiceGroupParams,
    voiceGroupParamDefaults: voiceGroupParamDefaults,
    voiceDescription: voiceDescription,
    voiceHidden: voiceHidden,
    reversible: reversible,
  );
}
