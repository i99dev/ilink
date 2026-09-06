/// Engine-internal compiled form of a `WorkflowDocument` (Phase-A
/// subset) + the fail-closed compiler that produces it.
///
/// The canonical document grammar lives in `ilink-sdk`
/// `types/workflow.ts`; this is the narrow shape the Phase-A on-car
/// engine can actually execute:
///
///   * ONE `signal.threshold` trigger
///   * an OPTIONAL single `signal_compare` condition (true/false branch)
///   * `car_command` action chains
///
/// [compileWorkflowDocument] is FAIL-CLOSED: any node kind / type / shape
/// the engine doesn't implement yields a [CompileResult] with an error
/// and NO runnable workflow — the engine refuses to arm rather than
/// mis-running. This mirrors the SDK's `assessWorkflowSupport` gate; the
/// canvas runs the same check at save time (free-wire authoring).
library;

import '../../_car_domain/command/command.dart' show SecurityClass;
import 'wf_expr.dart';

/// Trigger types this engine BUILD implements (Phase A). Mirrors the
/// SDK `WorkflowSupport.triggerTypes` the canvas validates against.
const Set<String> kEngineTriggerTypes = {
  'signal.threshold',
  'signal.changed',
  'signal.transition',
  'time.interval',
  'time.at',
  'geo.enter',
  'geo.exit',
  'geo.dwell',
  'voice.phrase',
};
const Set<String> kEngineConditionTypes = {'signal_compare', 'logic_group'};
const Set<String> kEngineActionTypes = {
  'car_command',
  'radio',
  'app',
  'delay',
  'notify',
  'set_var',
};

/// Hard ceiling on an in-chain `delay`. A delay holds an in-flight run
/// (and its post-delay state checks get less reliable the longer it
/// waits); anything longer than this should be a scheduled trigger, not a
/// delay. Over-long delays are CLAMPED to this at compile time (the SDK
/// schema permits up to 24h; the engine refuses to honor that).
const int kMaxWorkflowDelayMs = 3600000; // 1 hour

enum WfCompareOp { lt, lte, eq, ne, gte, gt }

WfCompareOp? parseCompareOp(String s) => switch (s) {
  '<' => WfCompareOp.lt,
  '<=' => WfCompareOp.lte,
  '==' => WfCompareOp.eq,
  '!=' => WfCompareOp.ne,
  '>=' => WfCompareOp.gte,
  '>' => WfCompareOp.gt,
  _ => null,
};

bool evalCompare(num a, WfCompareOp op, num b) => switch (op) {
  WfCompareOp.lt => a < b,
  WfCompareOp.lte => a <= b,
  WfCompareOp.eq => a == b,
  WfCompareOp.ne => a != b,
  WfCompareOp.gte => a >= b,
  WfCompareOp.gt => a > b,
};

/// Edge-detection mode. `rising` is the SAFE default — fire only on a
/// false→true transition, never re-fire while the predicate stays true.
enum WfEdgeMode { rising, falling, both, level }

WfEdgeMode parseEdgeMode(String? s) => switch (s) {
  'falling' => WfEdgeMode.falling,
  'both' => WfEdgeMode.both,
  'level' => WfEdgeMode.level,
  _ => WfEdgeMode.rising,
};

SecurityClass parseSecurityClass(String? s) => switch (s) {
  'safety' => SecurityClass.safety,
  'security' => SecurityClass.security,
  _ => SecurityClass.none,
};

/// A single comparison predicate (used by [TransitionTrigger] from/to).
class WfPredicate {
  const WfPredicate(this.op, this.value);
  final WfCompareOp op;
  final num value;
  bool matches(int? v) => v != null && evalCompare(v, op, value);
}

/// Parse a predicate string like `">5"` / `"==0"` → `(op, value)`.
WfPredicate? parsePredicate(String s) {
  final m = RegExp(
    r'^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$',
  ).firstMatch(s);
  if (m == null) return null;
  final op = parseCompareOp(m.group(1)!);
  final val = num.tryParse(m.group(2)!);
  if (op == null || val == null) return null;
  return WfPredicate(op, val);
}

/// Compiled trigger — SEALED over two families: [SignalTrigger]
/// (evaluated on each CAN push frame) and [TimeTrigger] (evaluated by the
/// engine's wall-clock ticker). Carries the universal anti-storm controls.
sealed class CompiledTrigger {
  const CompiledTrigger({
    required this.debounce,
    required this.cooldown,
    required this.staleGuard,
  });

  final Duration debounce;
  final Duration cooldown;

  /// Refuse to fire if the signal's freshness is older than this
  /// (`Duration.zero` = no guard). Fail-closed for signal triggers;
  /// unused by time triggers.
  final Duration staleGuard;
}

/// A trigger driven by the CAN signal stream. Watches exactly one
/// [signal]; the engine indexes watchers by it so a frame only wakes the
/// workflows that track that name.
sealed class SignalTrigger extends CompiledTrigger {
  const SignalTrigger({
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  String get signal;
}

/// A trigger driven by the wall clock (NOT the signal stream). Fires only
/// while the engine is running — wake-on-asleep (firing on a parked/off
/// car) needs the server-side path and is NOT implemented on-car.
sealed class TimeTrigger extends CompiledTrigger {
  const TimeTrigger({
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });
}

/// Fire every [every] while the engine runs (anchored at arm time).
class IntervalTrigger extends TimeTrigger {
  const IntervalTrigger({
    required this.every,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  final Duration every;
}

/// Fire at [hour]:[minute] (car-local) on the listed [daysOfWeek]
/// (0=Sun..6=Sat; empty = every day), once per occurrence.
class TimeOfDayTrigger extends TimeTrigger {
  const TimeOfDayTrigger({
    required this.hour,
    required this.minute,
    required this.daysOfWeek,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  final int hour;
  final int minute;
  final Set<int> daysOfWeek;
}

/// A trigger driven by the GPS stream (NOT the signal stream). Reuses
/// the host's proven custom-GNSS location feed; circle geofence with
/// enter/exit hysteresis.
enum WfGeoEvent { enter, exit, dwell }

class GeoTrigger extends CompiledTrigger {
  const GeoTrigger({
    required this.event,
    required this.lat,
    required this.lng,
    required this.enterRadiusM,
    required this.exitRadiusM,
    required this.dwell,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  final WfGeoEvent event;
  final double lat;
  final double lng;

  /// Distance ≤ this ⇒ inside. [exitRadiusM] (≥ enter) ⇒ outside — the
  /// gap is hysteresis that kills GPS-jitter chatter at the boundary.
  final double enterRadiusM;
  final double exitRadiusM;

  /// Minimum continuous time inside before a `dwell` event fires.
  final Duration dwell;
}

// Phrase normalization for voice matching: lowercase, drop punctuation
// (Unicode-aware so Arabic/other scripts survive), collapse whitespace.
final RegExp _kPhrasePunct = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);
final RegExp _kPhraseWs = RegExp(r'\s+');
String normalizeVoicePhrase(String s) => s
    .toLowerCase()
    .replaceAll(_kPhrasePunct, ' ')
    .replaceAll(_kPhraseWs, ' ')
    .trim();

/// A trigger fired by the on-device voice recognizer when the user speaks
/// one of its [phrases]. NOT driven by a signal/clock/GPS: an external
/// source (the voice router) calls `WorkflowEngine.onVoicePhrase(spoken)`,
/// which asks each voice trigger whether [spoken] [matches]. The phrase
/// set also feeds the Vosk grammar so the recognizer can hear it.
class VoiceTrigger extends CompiledTrigger {
  VoiceTrigger({
    required Iterable<String> phrases,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  }) : phrases = List<String>.unmodifiable({
         for (final p in phrases)
           if (normalizeVoicePhrase(p).isNotEmpty) normalizeVoicePhrase(p),
       });

  /// Normalized phrase variants (the primary `phrase` + any `examples`).
  final List<String> phrases;

  /// True when [spoken] contains one of this trigger's phrases as a
  /// contiguous WHOLE-WORD run. This tolerates an un-stripped wake prefix
  /// ("hey byd movie time") and trailing politeness ("movie time please"),
  /// while NOT over-firing on substrings — phrase "open" won't match
  /// "opener" (token-level, not character `contains`).
  bool matches(String spoken) {
    final s = normalizeVoicePhrase(spoken);
    if (s.isEmpty) return false;
    final words = s.split(' ');
    for (final p in phrases) {
      if (s == p) return true;
      if (_containsWordRun(words, p.split(' '))) return true;
    }
    return false;
  }

  static bool _containsWordRun(List<String> hay, List<String> needle) {
    if (needle.isEmpty || needle.length > hay.length) return false;
    for (var i = 0; i + needle.length <= hay.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }
}

/// Fire on an EDGE of `signal <op> value` (rising by default).
class ThresholdTrigger extends SignalTrigger {
  const ThresholdTrigger({
    required this.signal,
    required this.op,
    required this.value,
    required this.edge,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  @override
  final String signal;
  final WfCompareOp op;
  final num value;
  final WfEdgeMode edge;

  /// The predicate against a (possibly null) current value. Null reads
  /// are always `false` (fail-closed).
  bool test(int? current) => current != null && evalCompare(current, op, value);
}

/// Fire whenever `signal`'s value CHANGES (any delta).
class ChangedTrigger extends SignalTrigger {
  const ChangedTrigger({
    required this.signal,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  @override
  final String signal;
}

/// Fire when `signal` goes FROM matching [from] TO matching [to] —
/// e.g. `speed_kmh` from `>5` to `==0` ("just parked").
class TransitionTrigger extends SignalTrigger {
  const TransitionTrigger({
    required this.signal,
    required this.from,
    required this.to,
    required super.debounce,
    required super.cooldown,
    required super.staleGuard,
  });

  @override
  final String signal;
  final WfPredicate from;
  final WfPredicate to;
}

/// Boolean combinator for a [LogicGroupCondition].
enum WfGroupOp { and, or }

WfGroupOp? parseGroupOp(String s) => switch (s) {
  'and' => WfGroupOp.and,
  'or' => WfGroupOp.or,
  _ => null,
};

/// Compiled condition (the "IF") — SEALED over a single comparison and a
/// one-level AND/OR group. Evaluates against a value reader so a group
/// can read several signals.
sealed class CompiledCondition {
  const CompiledCondition({required this.staleGuard});

  /// Fail-closed freshness guard applied to ALL [signals] (0 = none).
  final Duration staleGuard;

  /// Every signal this condition reads (for the stale guard).
  Set<String> get signals;

  bool evaluate(int? Function(String signal) read);
}

/// A single `signal <op> value` comparison.
class CompareCondition extends CompiledCondition {
  const CompareCondition({
    required this.signal,
    required this.op,
    required this.value,
    required super.staleGuard,
  });

  final String signal;
  final WfCompareOp op;
  final num value;

  @override
  Set<String> get signals => {signal};

  @override
  bool evaluate(int? Function(String) read) {
    final v = read(signal);
    return v != null && evalCompare(v, op, value);
  }
}

/// One-level boolean group: `and` (all rules) / `or` (any rule). (`not`
/// is reserved in the grammar but not yet run by this engine build.)
class LogicGroupCondition extends CompiledCondition {
  const LogicGroupCondition({
    required this.groupOp,
    required this.rules,
    required super.staleGuard,
  });

  final WfGroupOp groupOp;
  final List<CompareCondition> rules;

  @override
  Set<String> get signals => {for (final r in rules) r.signal};

  @override
  bool evaluate(int? Function(String) read) => switch (groupOp) {
    WfGroupOp.and => rules.every((r) => r.evaluate(read)),
    WfGroupOp.or => rules.any((r) => r.evaluate(read)),
  };
}

/// Compiled `car_command` action with the safety metadata the engine
/// gates on (sourced from the document's action `flags`, which the
/// canvas populated from `workflow.catalog`).
class CompiledAction {
  const CompiledAction({
    required this.type,
    required this.actionId,
    required this.args,
    required this.securityClass,
    required this.requiresStationary,
    this.varName,
    this.expr,
  });

  /// Action node type — routes dispatch: `car_command` → the command
  /// router, `radio` → the in-app player, `app` → the app launcher,
  /// `delay` → an in-chain wait (engine-local), `notify` → a user
  /// message (engine-local), `cluster` → the cluster renderer.
  final String type;
  final String actionId;
  final Map<String, Object?> args;
  final SecurityClass securityClass;
  final bool requiresStationary;

  /// `set_var` only: the variable name to assign and the compiled
  /// expression to evaluate. Null for every other action type.
  final String? varName;
  final WfExpr? expr;

  /// Any non-none action is gated by the engine's INDEPENDENT stationary
  /// check for a background trigger — regardless of [requiresStationary]
  /// (window.close is safety-class yet not flagged for human taps).
  bool get gatedWhileMoving => securityClass != SecurityClass.none;

  /// Security-class actions additionally require explicit confirmation
  /// before a background trigger may run them.
  bool get requiresConfirm => securityClass == SecurityClass.security;
}

/// Action types whose effect reaches outside the engine and therefore
/// need the owner's explicit consent for an IMPORTED workflow (a car
/// command, a media takeover, a launched app, or a metered AI turn). The
/// benign engine-local steps (`delay`/`notify`/`cluster`) never need it.
const Set<String> kConsentGatedActionTypes = {
  'car_command',
  'radio',
  'app',
  'ai',
};

/// A fully-compiled, runnable workflow (Phase-A subset).
class CompiledWorkflow {
  const CompiledWorkflow({
    required this.id,
    required this.name,
    required this.enabled,
    required this.trigger,
    required this.condition,
    required this.trueActions,
    required this.falseActions,
    required this.autoConfirm,
    this.source = 'authored',
    this.consentedActions = const {},
  });

  final String id;
  final String name;
  final bool enabled;
  final CompiledTrigger trigger;

  /// Provenance. `imported` (from a shared template) means the engine
  /// refuses any consent-gated action until its id is in
  /// [consentedActions] — the owner approves them in-car (plan §8/§12).
  final String source;

  /// Action ids the owner consented to (only meaningful when
  /// `source == 'imported'`).
  final Set<String> consentedActions;

  /// Null when the workflow is trigger→action with no condition (the
  /// action chain is [trueActions]).
  final CompiledCondition? condition;
  final List<CompiledAction> trueActions;
  final List<CompiledAction> falseActions;

  /// When true, the owner pre-consented to security-class actions
  /// running from a background trigger (otherwise they are blocked).
  final bool autoConfirm;

  /// Every catalog signal name this workflow watches — the trigger
  /// signal plus the condition signal. The engine indexes watchers by
  /// these so a CAN frame only wakes the workflows that track its name.
  Set<String> get watchedSignals => {
    if (trigger case final SignalTrigger t) t.signal,
    if (condition != null) ...condition!.signals,
  };

  /// Whether [action] is allowed to run. Authored workflows allow
  /// everything; an imported one allows benign engine-local steps but
  /// refuses a consent-gated action until its id is consented. Fail-closed
  /// — an imported workflow with no consent runs nothing dangerous.
  bool isConsented(CompiledAction action) {
    if (source != 'imported') return true;
    if (!kConsentGatedActionTypes.contains(action.type)) return true;
    return consentedActions.contains(action.actionId);
  }
}

/// Result of [compileWorkflowDocument]: exactly one of [workflow] /
/// [error] is non-null.
class CompileResult {
  const CompileResult.ok(this.workflow) : error = null;
  const CompileResult.fail(this.error) : workflow = null;

  final CompiledWorkflow? workflow;
  final String? error;

  bool get ok => workflow != null;
}

/// Compile a `WorkflowDocument` JSON map into a [CompiledWorkflow], or
/// return a fail-closed error for any shape this engine build can't run.
CompileResult compileWorkflowDocument(Map<String, Object?> doc) {
  final id = doc['workflowId'];
  if (id is! String || id.isEmpty) {
    return const CompileResult.fail('missing workflowId');
  }
  final name = (doc['name'] as String?) ?? id;
  final enabled = (doc['enabled'] as bool?) ?? true;
  final autoConfirm = (doc['autoConfirm'] as bool?) ?? false;
  final source = (doc['source'] as String?) ?? 'authored';
  final consentedActions = <String>{
    for (final a in (doc['consentedActions'] as List?) ?? const [])
      if (a is String) a,
  };

  final nodesRaw = doc['nodes'];
  if (nodesRaw is! List) return CompileResult.fail('$id: nodes missing');

  final nodes = <String, Map<String, Object?>>{};
  Map<String, Object?>? triggerNode;
  Map<String, Object?>? conditionNode;
  var actionCount = 0;
  for (final n in nodesRaw) {
    if (n is! Map) return CompileResult.fail('$id: malformed node');
    final node = n.cast<String, Object?>();
    final nid = node['id'];
    final kind = node['kind'];
    final type = node['type'];
    if (nid is! String) return CompileResult.fail('$id: node missing id');
    nodes[nid] = node;
    switch (kind) {
      case 'trigger':
        if (triggerNode != null) {
          return CompileResult.fail('$id: Phase-A supports a single trigger');
        }
        if (!kEngineTriggerTypes.contains(type)) {
          return CompileResult.fail('$id: unsupported trigger type "$type"');
        }
        triggerNode = node;
      case 'condition':
        if (conditionNode != null) {
          return CompileResult.fail('$id: Phase-A supports a single condition');
        }
        if (!kEngineConditionTypes.contains(type)) {
          return CompileResult.fail('$id: unsupported condition type "$type"');
        }
        conditionNode = node;
      case 'action':
        if (!kEngineActionTypes.contains(type)) {
          return CompileResult.fail('$id: unsupported action type "$type"');
        }
        actionCount++;
      case 'cluster_output':
        // A "do something" terminal like an action — satisfies the
        // ≥1-action requirement (a workflow may just render to cluster).
        actionCount++;
      default:
        return CompileResult.fail('$id: unknown node kind "$kind"');
    }
  }
  if (triggerNode == null) return CompileResult.fail('$id: no trigger node');
  if (actionCount == 0) return CompileResult.fail('$id: no action node');

  final trigger = _compileTrigger(id, triggerNode);
  if (trigger == null) return CompileResult.fail('$id: invalid trigger config');

  CompiledCondition? condition;
  if (conditionNode != null) {
    condition = _compileCondition(conditionNode);
    if (condition == null) {
      return CompileResult.fail('$id: invalid condition config');
    }
  }

  // Build adjacency from edges: from → list of (to, when).
  final edgesRaw = (doc['edges'] as List?) ?? const [];
  final adj = <String, List<({String to, String? when})>>{};
  for (final e in edgesRaw) {
    if (e is! Map) return CompileResult.fail('$id: malformed edge');
    final from = e['from'];
    final to = e['to'];
    if (from is! String || to is! String) {
      return CompileResult.fail('$id: edge missing from/to');
    }
    (adj[from] ??= []).add((to: to, when: e['when'] as String?));
  }

  final triggerId = triggerNode['id'] as String;
  List<CompiledAction>? chainFrom(String entry, {String? branch}) =>
      _buildChain(id, entry, branch: branch, nodes: nodes, adj: adj);

  List<CompiledAction> trueActions;
  List<CompiledAction> falseActions = const [];
  if (condition != null) {
    final condId = adj[triggerId]?.firstOrNull?.to;
    if (condId == null || nodes[condId]?['kind'] != 'condition') {
      return CompileResult.fail('$id: trigger must connect to the condition');
    }
    final t = chainFrom(condId, branch: 'true');
    if (t == null) return CompileResult.fail('$id: invalid true-branch chain');
    trueActions = t;
    falseActions = chainFrom(condId, branch: 'false') ?? const [];
  } else {
    final t = chainFrom(triggerId);
    if (t == null || t.isEmpty) {
      return CompileResult.fail('$id: trigger must connect to an action');
    }
    trueActions = t;
  }

  return CompileResult.ok(
    CompiledWorkflow(
      id: id,
      name: name,
      enabled: enabled,
      trigger: trigger,
      condition: condition,
      trueActions: trueActions,
      falseActions: falseActions,
      autoConfirm: autoConfirm,
      source: source,
      consentedActions: consentedActions,
    ),
  );
}

CompiledTrigger? _compileTrigger(String id, Map<String, Object?> node) {
  final type = node['type'] as String?;
  final cfg = (node['config'] as Map?)?.cast<String, Object?>() ?? const {};
  final debounce = Duration(
    milliseconds: (node['debounceMs'] as num?)?.toInt() ?? 0,
  );
  final cooldown = Duration(
    milliseconds: (node['cooldownMs'] as num?)?.toInt() ?? 0,
  );
  final staleGuard = Duration(
    milliseconds: (node['staleGuardMs'] as num?)?.toInt() ?? 0,
  );

  // Signal triggers key the signal as `name` (matching the SDK schema;
  // the signal_compare condition uses `signal`). Time triggers have none.
  switch (type) {
    case 'signal.threshold':
      final signal = cfg['name'];
      final op = parseCompareOp(cfg['op'] as String? ?? '');
      final value = cfg['value'];
      if (signal is! String || op == null || value is! num) return null;
      return ThresholdTrigger(
        signal: signal,
        op: op,
        value: value,
        edge: parseEdgeMode(node['edge'] as String?),
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'signal.changed':
      final signal = cfg['name'];
      if (signal is! String) return null;
      return ChangedTrigger(
        signal: signal,
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'signal.transition':
      final signal = cfg['name'];
      final from = parsePredicate(cfg['from'] as String? ?? '');
      final to = parsePredicate(cfg['to'] as String? ?? '');
      if (signal is! String || from == null || to == null) return null;
      return TransitionTrigger(
        signal: signal,
        from: from,
        to: to,
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'time.interval':
      final everyMin = (cfg['everyMin'] as num?)?.toInt() ?? 0;
      if (everyMin < 1) return null;
      return IntervalTrigger(
        every: Duration(minutes: everyMin),
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'time.at':
      final hm = _parseHhmm(cfg['hhmm'] as String? ?? '');
      if (hm == null) return null;
      final days = <int>{
        for (final d in (cfg['daysOfWeek'] as List?) ?? const [])
          if (d is num && d >= 0 && d <= 6) d.toInt(),
      };
      return TimeOfDayTrigger(
        hour: hm.$1,
        minute: hm.$2,
        daysOfWeek: days,
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'geo.enter':
    case 'geo.exit':
    case 'geo.dwell':
      // Circle only in Phase B (polygon later).
      if ((cfg['shape'] as String? ?? 'circle') != 'circle') return null;
      final lat = (cfg['lat'] as num?)?.toDouble();
      final lng = (cfg['lng'] as num?)?.toDouble();
      final radius = (cfg['radiusM'] as num?)?.toDouble();
      if (lat == null || lng == null || radius == null || radius <= 0) {
        return null;
      }
      final enterR = (cfg['enterRadiusM'] as num?)?.toDouble() ?? radius;
      var exitR = (cfg['exitRadiusM'] as num?)?.toDouble() ?? radius * 1.2;
      if (exitR < enterR) exitR = enterR; // hysteresis must be ≥ enter
      final event = switch (type) {
        'geo.enter' => WfGeoEvent.enter,
        'geo.exit' => WfGeoEvent.exit,
        _ => WfGeoEvent.dwell,
      };
      final dwellSec = (cfg['dwellSec'] as num?)?.toInt() ?? 0;
      if (event == WfGeoEvent.dwell && dwellSec < 1) return null;
      return GeoTrigger(
        event: event,
        lat: lat,
        lng: lng,
        enterRadiusM: enterR,
        exitRadiusM: exitR,
        dwell: Duration(seconds: dwellSec),
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
    case 'voice.phrase':
      final phrase = cfg['phrase'];
      if (phrase is! String || normalizeVoicePhrase(phrase).isEmpty) {
        return null;
      }
      final examples = <String>[
        phrase,
        for (final e in (cfg['examples'] as List?) ?? const [])
          if (e is String) e,
      ];
      final trig = VoiceTrigger(
        phrases: examples,
        debounce: debounce,
        cooldown: cooldown,
        staleGuard: staleGuard,
      );
      // Fail closed if nothing normalized to a usable phrase.
      return trig.phrases.isEmpty ? null : trig;
    default:
      return null;
  }
}

/// Parse `"HH:MM"` (24-hour) → `(hour, minute)`, or null if malformed.
(int, int)? _parseHhmm(String s) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(s);
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

CompiledCondition? _compileCondition(Map<String, Object?> node) {
  final type = node['type'] as String?;
  final cfg = (node['config'] as Map?)?.cast<String, Object?>() ?? const {};
  final staleGuard = Duration(
    milliseconds: (node['staleGuardMs'] as num?)?.toInt() ?? 0,
  );
  switch (type) {
    case 'signal_compare':
      return _compileCompare(cfg, staleGuard);
    case 'logic_group':
      final groupOp = parseGroupOp(cfg['op'] as String? ?? '');
      final rulesRaw = cfg['rules'];
      if (groupOp == null || rulesRaw is! List || rulesRaw.isEmpty) return null;
      final rules = <CompareCondition>[];
      for (final r in rulesRaw) {
        if (r is! Map) return null;
        final rc = _compileCompare(r.cast<String, Object?>(), Duration.zero);
        if (rc == null) return null;
        rules.add(rc);
      }
      return LogicGroupCondition(
        groupOp: groupOp,
        rules: rules,
        staleGuard: staleGuard,
      );
    default:
      return null;
  }
}

CompareCondition? _compileCompare(
  Map<String, Object?> cfg,
  Duration staleGuard,
) {
  final signal = cfg['signal'];
  final op = parseCompareOp(cfg['op'] as String? ?? '');
  final value = cfg['value'];
  if (signal is! String || op == null || value is! num) return null;
  return CompareCondition(
    signal: signal,
    op: op,
    value: value,
    staleGuard: staleGuard,
  );
}

/// Follow `from → action → action …` edges into an ordered action list.
/// For a condition entry, picks the edge whose `when` matches [branch].
List<CompiledAction>? _buildChain(
  String id,
  String entry, {
  String? branch,
  required Map<String, Map<String, Object?>> nodes,
  required Map<String, List<({String to, String? when})>> adj,
}) {
  final out = <CompiledAction>[];
  final seen = <String>{};
  // First hop: from the entry, pick the matching branch edge.
  String? next = adj[entry]
      ?.firstWhere(
        (e) => branch == null ? true : e.when == branch,
        orElse: () => (to: '', when: null),
      )
      .to;
  if (next == null || next.isEmpty) {
    // A condition with no matching branch is valid (e.g. no false-branch).
    return branch == null ? null : const [];
  }
  while (next != null && next.isNotEmpty) {
    if (!seen.add(next)) return null; // cycle — fail closed
    final node = nodes[next];
    if (node == null) return null;
    final kind = node['kind'];
    final CompiledAction? step;
    if (kind == 'action') {
      step = _compileAction(node);
    } else if (kind == 'cluster_output') {
      step = _compileClusterOutput(node);
    } else {
      return null;
    }
    if (step == null) return null;
    out.add(step);
    // Continue down un-labelled chain edges (action / cluster_output).
    next = adj[next]
        ?.firstWhere((e) => e.when == null, orElse: () => (to: '', when: null))
        .to;
  }
  return out;
}

/// Compile a `cluster_output` node into a 'cluster' action step. The
/// config (displayTarget / route / mode / ttlMs / layoutB64) is passed
/// to the engine's injected cluster renderer verbatim as args.
CompiledAction? _compileClusterOutput(Map<String, Object?> node) {
  final cfg = (node['config'] as Map?)?.cast<String, Object?>() ?? const {};
  final route = cfg['route'];
  if (route is! String || route.isEmpty) return null;
  return CompiledAction(
    type: 'cluster',
    actionId: route,
    args: cfg,
    securityClass: SecurityClass.none,
    requiresStationary: false,
  );
}

CompiledAction? _compileAction(Map<String, Object?> node) {
  final type = (node['type'] as String?) ?? 'car_command';
  final cfg = (node['config'] as Map?)?.cast<String, Object?>() ?? const {};

  // Engine-local control-flow actions carry their config directly (no
  // dispatchable `actionId`); they are always securityClass.none.
  switch (type) {
    case 'delay':
      final ms = (cfg['ms'] as num?)?.toInt();
      if (ms == null || ms < 0) return null;
      // Clamp to the engine ceiling (see kMaxWorkflowDelayMs).
      final clamped = ms > kMaxWorkflowDelayMs ? kMaxWorkflowDelayMs : ms;
      return CompiledAction(
        type: 'delay',
        actionId: 'delay',
        args: {'ms': clamped},
        securityClass: SecurityClass.none,
        requiresStationary: false,
      );
    case 'notify':
      final title = cfg['title'];
      if (title is! String || title.isEmpty) return null;
      return CompiledAction(
        type: 'notify',
        actionId: 'notify',
        args: {
          'title': title,
          if (cfg['body'] is String) 'body': cfg['body'],
          if (cfg['target'] is String) 'target': cfg['target'],
        },
        securityClass: SecurityClass.none,
        requiresStationary: false,
      );
    case 'set_var':
      final name = cfg['name'];
      final exprSrc = cfg['expr'];
      if (name is! String || name.isEmpty) return null;
      if (exprSrc is! String) return null;
      final expr = WfExpr.tryParse(exprSrc);
      if (expr == null) return null; // fail-closed on a malformed expression
      return CompiledAction(
        type: 'set_var',
        actionId: 'set_var',
        args: const {},
        securityClass: SecurityClass.none,
        requiresStationary: false,
        varName: name,
        expr: expr,
      );
    default:
      // car_command / radio / app — dispatched by `actionId` with the
      // safety flags the canvas sourced from `workflow.catalog`.
      final actionId = cfg['actionId'];
      if (actionId is! String || actionId.isEmpty) return null;
      final args = (cfg['args'] as Map?)?.cast<String, Object?>() ?? const {};
      final flags =
          (node['flags'] as Map?)?.cast<String, Object?>() ?? const {};
      return CompiledAction(
        type: type,
        actionId: actionId,
        args: args,
        securityClass: parseSecurityClass(flags['securityClass'] as String?),
        requiresStationary: (flags['requiresStationary'] as bool?) ?? false,
      );
  }
}
