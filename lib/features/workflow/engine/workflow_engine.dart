/// The on-car workflow execution engine (Phase-A core).
///
/// Runs continuously, decoupled from any editor screen. It subscribes
/// ONCE to `client.changes()` (with a name→watcher index so a CAN frame
/// only wakes the workflows that track its signal), applies the
/// universal anti-storm controls (rising-edge detection + debounce +
/// cooldown + a global runaway governor), and dispatches actions through
/// the EXISTING `CarClient.dispatch` chokepoint — inheriting integrity /
/// rate-limit / stationary / audit. It adds ZERO new dispatch path.
///
/// Three safety properties this core is responsible for:
///
///   * §6.1 — an INDEPENDENT engine-level stationary gate blocks any
///     `safety`/`security`-class action for a moving car, regardless of
///     the per-command `requiresStationary` flag (window.close is
///     safety-class yet ungated for human taps).
///   * §6.3 — the engine NEVER caches a CarClient. The provider re-binds
///     it via `ref.listen` on every brand re-resolve, and `bindClient`
///     re-establishes the `changes()` subscription + RE-SEEDS every
///     watcher's edge-state (no phantom rising edge after a rebind or a
///     daemon reconnect). This is the verified fix for the disposed-Ref
///     "can't reach car" bug.
///   * §6.6 — a global + per-workflow runaway governor disables a
///     self-firing workflow rather than depending on action→signal
///     causality the registry doesn't model.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../sdk/car/client.dart';
import '../../_car_domain/consumer/car_consumer.dart';
import 'compiled_workflow.dart';

/// Speed (km/h) above which the engine refuses a safety/security action
/// for a background trigger. Matches `CarCommandRouter`'s own limit.
const int kEngineStationarySpeedLimit = 5;

/// Runaway governor: a workflow that fires more than this within
/// [kGovernorWindow] is disabled and flagged (a self-firing loop on a
/// real car is a safety event, not a perf nuisance).
const int kMaxRunsPerWorkflowPerWindow = 12;

/// Global cap across ALL workflows in the same window (defence against a
/// fleet of workflows collectively storming the bus).
const int kMaxRunsGlobalPerWindow = 60;

const Duration kGovernorWindow = Duration(minutes: 1);

/// Dispatches a non-car_command action to its subsystem (radio / apps).
/// Returns the outcome map (`{ok}` / `{error}`), matching
/// `CarClient.dispatch`. Injected into the engine for testability.
typedef WorkflowSubDispatch =
    Future<Map<String, Object?>> Function(
      String actionId,
      Map<String, Object?> args,
    );

/// Why an action did not run / how a run ended — surfaced to the
/// (future) run-log + used by tests.
enum WorkflowRunOutcome {
  fired,
  blockedWhileMoving,
  needsConfirm,
  notConsented,
  dispatchFailed,
  suppressed,
}

/// Per-workflow reactive state held by the engine.
class _Watcher {
  _Watcher(this.wf);
  final CompiledWorkflow wf;

  /// Last evaluated threshold predicate — the edge-detection memory
  /// (threshold triggers only). `null` until seeded; re-seeded (without
  /// firing) on every client rebind / reconnect.
  bool? lastPredicate;

  /// Last raw signal value — the change/transition memory (changed +
  /// transition triggers). Re-seeded alongside [lastPredicate].
  int? lastValue;

  /// When the current fireable "arm" began (for debounce). Cleared when
  /// the predicate leaves the fireable state.
  DateTime? armedSince;

  /// True once this arm has fired (transition modes fire once per arm).
  bool firedForArm = false;

  /// Last accepted fire (for cooldown).
  DateTime? lastFire;

  /// Accepted-fire timestamps within the governor window.
  final List<DateTime> runHistory = [];

  /// time.at fire-once-per-occurrence key (`y-m-d-h-m`); null until fired.
  String? lastTimeFireKey;

  /// Geofence state: inside the region (with hysteresis), when the
  /// current dwell began, and whether this dwell already fired.
  bool? geoInside;
  DateTime? geoDwellSince;
  bool geoDwellFired = false;

  /// Tripped by the runaway governor — stops evaluating until reloaded.
  bool disabled = false;
}

class WorkflowEngine {
  WorkflowEngine({
    DateTime Function()? clock,
    Future<int?> Function(CarClient client)? speedReader,
    WorkflowSubDispatch? dispatchRadio,
    WorkflowSubDispatch? dispatchApp,
    WorkflowSubDispatch? dispatchCluster,
    WorkflowSubDispatch? dispatchNotify,
    Future<void> Function(Duration)? delay,
  }) : _now = clock ?? DateTime.now,
       _readSpeed = speedReader ?? _defaultSpeedReader,
       _dispatchRadio = dispatchRadio,
       _dispatchApp = dispatchApp,
       _dispatchCluster = dispatchCluster,
       _dispatchNotify = dispatchNotify,
       _delay = delay ?? Future<void>.delayed;

  /// Routes a non-car_command action to its subsystem (radio player /
  /// app launcher / cluster renderer / user notification). Injected so
  /// the engine doesn't import those subsystems directly and stays
  /// unit-testable. Returns the outcome map (`{ok}` / `{error}`), same
  /// shape as `CarClient.dispatch`.
  final WorkflowSubDispatch? _dispatchRadio;
  final WorkflowSubDispatch? _dispatchApp;
  final WorkflowSubDispatch? _dispatchCluster;
  final WorkflowSubDispatch? _dispatchNotify;

  /// In-chain `delay` waiter. Injected so tests run instantly; defaults
  /// to a real wall-clock wait. The chain re-checks liveness after it.
  final Future<void> Function(Duration) _delay;

  final DateTime Function() _now;
  final Future<int?> Function(CarClient client) _readSpeed;

  /// Vehicle-speed signal the engine's stationary gate reads — same as
  /// `CarCommandRouter`'s. Ground-truth: trust a cached value younger
  /// than 3 s, else force a live read (deltas-only brands can leave a
  /// stale "moving" value cached on a parked car).
  static const String _speedSignal = 'Statistic.STATISTIC_SPEED_SIG_VDIS';

  static Future<int?> _defaultSpeedReader(CarClient client) async {
    final age = client.freshness(_speedSignal);
    if (age != null && age <= const Duration(seconds: 3)) {
      return client.value(_speedSignal);
    }
    return client
        .refreshValue(_speedSignal)
        .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
  }

  CarClient? _client;
  StreamSubscription<String>? _changesSub;
  StreamSubscription<DaemonState>? _connSub;
  DaemonState _lastConn = DaemonState.connected;

  final Map<String, _Watcher> _watchers = {}; // workflowId → watcher
  final Map<String, List<_Watcher>> _byTriggerSignal = {}; // signal → watchers
  final List<_Watcher> _timeWatchers = []; // time.* triggers (clock-driven)
  final List<_Watcher> _geoWatchers = []; // geo.* triggers (location-driven)
  final List<_Watcher> _voiceWatchers = []; // voice.phrase (recognizer-driven)
  final List<DateTime> _globalRuns = [];

  /// How often the wall-clock ticker evaluates time triggers. 20 s
  /// catches a time.at minute reliably without busy-waking.
  static const Duration _kTimeCheckInterval = Duration(seconds: 20);
  Timer? _timeTimer;

  /// In-flight action runs — awaited by [drain] in tests.
  final List<Future<void>> _inFlight = [];

  bool _disposed = false;

  // ── client binding (the disposed-Ref fix) ──────────────────────────

  /// (Re)bind the engine to a CarClient. Idempotent for the same
  /// instance. On a NEW client (brand re-resolve) it tears down the old
  /// `changes()`/`connectionState()` subscriptions, re-seeds every
  /// watcher's edge-state from the new client (so the first frame can't
  /// manufacture a phantom edge), and re-arms.
  void bindClient(CarClient client) {
    if (_disposed || identical(client, _client)) return;
    // Tear down the old client's subscriptions AND null them, so
    // `_armIfNeeded` re-subscribes to the NEW client (a cancelled-but-
    // non-null handle would otherwise look "still armed").
    _changesSub?.cancel();
    _changesSub = null;
    _connSub?.cancel();
    _connSub = null;
    _client = client;
    _lastConn = client.currentConnectionState;
    _seedAll();
    _connSub = client.connectionState().listen(_onConnectionChanged);
    _armIfNeeded();
  }

  void loadWorkflows(List<CompiledWorkflow> workflows) {
    if (_disposed) return;
    final prevGeo = <String, _Watcher>{
      for (final e in _watchers.entries)
        if (e.value.wf.trigger is GeoTrigger) e.key: e.value,
    };
    _watchers.clear();
    for (final wf in workflows) {
      if (!wf.enabled) continue;
      final w = _Watcher(wf);
      final old = prevGeo[wf.id];
      if (old != null && _sameGeofence(old.wf.trigger, wf.trigger)) {
        w.geoInside = old.geoInside;
        w.geoDwellSince = old.geoDwellSince;
        w.geoDwellFired = old.geoDwellFired;
        w.lastFire = old.lastFire; // don't reset the cooldown anchor on reload
      }
      _watchers[wf.id] = w;
    }
    _reindex();
    _seedAll();
    _armIfNeeded();
  }

  /// True when two triggers are the SAME geofence (so membership state may be
  /// carried across a reload). A changed centre/radius/event/dwell returns
  /// false → the watcher resets, re-establishing membership from scratch.
  static bool _sameGeofence(CompiledTrigger a, CompiledTrigger b) {
    if (a is! GeoTrigger || b is! GeoTrigger) return false;
    return a.event == b.event &&
        a.lat == b.lat &&
        a.lng == b.lng &&
        a.enterRadiusM == b.enterRadiusM &&
        a.exitRadiusM == b.exitRadiusM &&
        a.dwell == b.dwell;
  }

  void _reindex() {
    _byTriggerSignal.clear();
    _timeWatchers.clear();
    _geoWatchers.clear();
    _voiceWatchers.clear();
    for (final w in _watchers.values) {
      final trig = w.wf.trigger;
      if (trig is SignalTrigger) {
        (_byTriggerSignal[trig.signal] ??= []).add(w);
      } else if (trig is TimeTrigger) {
        _timeWatchers.add(w);
        // Anchor interval triggers at load so the first fire is one
        // `every` from now (not immediately).
        if (trig is IntervalTrigger) w.lastFire = _now();
      } else if (trig is GeoTrigger) {
        _geoWatchers.add(w);
      } else if (trig is VoiceTrigger) {
        _voiceWatchers.add(w);
      }
    }
  }

  /// All distinct normalized phrases across the armed voice workflows —
  /// the single source the Vosk grammar layer reads so the recognizer can
  /// actually HEAR these phrases. Empty when no voice workflow is armed.
  Set<String> activeVoicePhrases() => {
    for (final w in _voiceWatchers)
      if (!w.disabled && w.wf.trigger is VoiceTrigger)
        ...(w.wf.trigger as VoiceTrigger).phrases,
  };

  /// External event source: the on-device voice router calls this when the
  /// recognizer emits a (wake-stripped) utterance. Fires every voice
  /// workflow whose trigger [matches], subject to the same cooldown +
  /// governor as any discrete trigger. No-op while disconnected (actions
  /// dispatch through the car) — same gate as the time/geo sources.
  ///
  /// Returns the NAME of the first voice workflow that matched (so the
  /// caller can suppress a built-in command for the same words — workflow
  /// wins — and show which automation it was), or null if none matched. A
  /// match returns non-null even if cooldown/governor suppressed the actual
  /// run, so a rapid repeat doesn't fall through to a built-in command.
  String? onVoicePhrase(String spoken) {
    if (_disposed) return null;
    final client = _client;
    if (client == null || _lastConn == DaemonState.disconnected) return null;
    final now = _now();
    String? firedName;
    for (final w in _voiceWatchers) {
      if (w.disabled) continue;
      final trig = w.wf.trigger;
      if (trig is VoiceTrigger && trig.matches(spoken)) {
        firedName ??= w.wf.name;
        _maybeFireDiscrete(w, client, now);
      }
    }
    return firedName;
  }

  /// Set each watcher's edge memory to the CURRENT predicate WITHOUT
  /// firing — the anti-phantom-edge seed run after a rebind/reconnect.
  void _seedAll() {
    final client = _client;
    for (final w in _watchers.values) {
      w.armedSince = null;
      w.firedForArm = false;
      final trig = w.wf.trigger;
      if (trig is SignalTrigger) {
        final raw = client?.value(trig.signal);
        w.lastValue = raw;
        w.lastPredicate = trig is ThresholdTrigger ? trig.test(raw) : null;
      }
      // Time watchers keep their interval anchor / fire-key across a
      // reseed (reconnect must not reset the clock or replay time.at).
    }
  }

  void _armIfNeeded() {
    final client = _client;
    if (client == null) return;
    // Signal stream — armed only when a signal watcher exists.
    final wantSignal = _byTriggerSignal.isNotEmpty;
    if (wantSignal && _changesSub == null) {
      _changesSub = client.changes().listen(_onFrame);
    } else if (!wantSignal && _changesSub != null) {
      _changesSub!.cancel();
      _changesSub = null;
    }
    // Wall-clock ticker — armed only when a time watcher exists.
    final wantTime = _timeWatchers.isNotEmpty;
    if (wantTime && _timeTimer == null) {
      _timeTimer = Timer.periodic(
        _kTimeCheckInterval,
        (_) => _onTimeTick(_now()),
      );
    } else if (!wantTime && _timeTimer != null) {
      _timeTimer!.cancel();
      _timeTimer = null;
    }
  }

  void _onConnectionChanged(DaemonState state) {
    final was = _lastConn;
    _lastConn = state;
    // On (re)connect, re-seed: edge-state held across a disconnect is
    // stale and a phantom transition on the first post-reconnect frame
    // could fire an action.
    if (state == DaemonState.connected && was != DaemonState.connected) {
      _seedAll();
    }
  }

  // ── evaluation ─────────────────────────────────────────────────────

  void _onFrame(String name) {
    if (_disposed) return;
    final now = _now();
    if (name.isEmpty) {
      // Batch / recheck-all frame.
      for (final w in _watchers.values) {
        _evaluate(w, now);
      }
      return;
    }
    final list = _byTriggerSignal[name];
    if (list == null) return; // O(1) skip for untracked names
    for (final w in list) {
      _evaluate(w, now);
    }
  }

  void _evaluate(_Watcher w, DateTime now) {
    if (w.disabled) return;
    final client = _client;
    if (client == null || _lastConn == DaemonState.disconnected) return;

    final trig = w.wf.trigger;
    if (trig is! SignalTrigger) return; // time triggers run via _onTimeTick

    // Stale guard — fail closed: if the signal is older than the guard
    // (or never seen), don't fire and drop all edge/change state.
    if (trig.staleGuard > Duration.zero) {
      final age = client.freshness(trig.signal);
      if (age == null || age > trig.staleGuard) {
        w.lastPredicate = null;
        w.lastValue = null;
        w.armedSince = null;
        w.firedForArm = false;
        return;
      }
    }

    final raw = client.value(trig.signal);
    switch (trig) {
      case final ThresholdTrigger t:
        _evaluateThreshold(w, t, raw, client, now);
      case ChangedTrigger _:
        final prev = w.lastValue;
        w.lastValue = raw;
        if (prev != null && raw != null && raw != prev) {
          _maybeFireDiscrete(w, client, now);
        }
      case final TransitionTrigger t:
        final prev = w.lastValue;
        w.lastValue = raw;
        if (t.from.matches(prev) && t.to.matches(raw)) {
          _maybeFireDiscrete(w, client, now);
        }
    }
  }

  /// Threshold edge-detection path (rising/falling/both/level + arm-dwell
  /// debounce). Unchanged semantics from Phase A.
  void _evaluateThreshold(
    _Watcher w,
    ThresholdTrigger t,
    int? raw,
    CarClient client,
    DateTime now,
  ) {
    final cur = t.test(raw);
    final prev = w.lastPredicate;
    w.lastPredicate = cur;
    w.lastValue = raw;

    final armed = _updateArm(w, t.edge, prev: prev, cur: cur, now: now);
    if (!armed) return;
    if (now.difference(w.armedSince!) < t.debounce) return; // debounce dwell
    if (t.edge != WfEdgeMode.level && w.firedForArm) return; // once per arm
    if (w.lastFire != null && now.difference(w.lastFire!) < t.cooldown) {
      return; // cooldown
    }
    if (!_governorAllows(w, now)) {
      _tripRunaway(w);
      return;
    }
    w.firedForArm = true;
    _commitFire(w, client, now);
  }

  /// Discrete-event path (changed / transition): a qualifying frame fires
  /// subject only to cooldown/debounce min-gap + the governor — no
  /// arm/dwell (the event itself is the edge).
  void _maybeFireDiscrete(_Watcher w, CarClient client, DateTime now) {
    final trig = w.wf.trigger;
    final minGap = trig.cooldown > trig.debounce
        ? trig.cooldown
        : trig.debounce;
    if (w.lastFire != null && now.difference(w.lastFire!) < minGap) return;
    if (!_governorAllows(w, now)) {
      _tripRunaway(w);
      return;
    }
    _commitFire(w, client, now);
  }

  /// Record the fire (cooldown + governor bookkeeping) and start the run.
  void _commitFire(_Watcher w, CarClient client, DateTime now) {
    w.lastFire = now;
    w.runHistory.add(now);
    _globalRuns.add(now);
    final f = _run(w, client);
    _inFlight.add(f);
    f.whenComplete(() => _inFlight.remove(f));
  }

  // ── time triggers (wall-clock driven) ──────────────────────────────

  /// Evaluate every time watcher against [now] — called by the periodic
  /// ticker (and directly by tests). `interval` fires every `every`
  /// (anchored at arm); `time.at` fires once per matching occurrence on
  /// the selected days. Both run only while connected (they dispatch).
  void _onTimeTick(DateTime now) {
    if (_disposed) return;
    final client = _client;
    if (client == null || _lastConn == DaemonState.disconnected) return;
    for (final w in _timeWatchers) {
      if (w.disabled) continue;
      final trig = w.wf.trigger;
      var due = false;
      if (trig is IntervalTrigger) {
        if (w.lastFire == null) {
          w.lastFire = now; // anchor — don't fire on the first tick
        } else if (now.difference(w.lastFire!) >= trig.every) {
          due = true;
        }
      } else if (trig is TimeOfDayTrigger) {
        final matchesTime = now.hour == trig.hour && now.minute == trig.minute;
        final matchesDay =
            trig.daysOfWeek.isEmpty ||
            trig.daysOfWeek.contains(now.weekday % 7);
        final key =
            '${now.year}-${now.month}-${now.day}-${trig.hour}-${trig.minute}';
        if (matchesTime && matchesDay && w.lastTimeFireKey != key) {
          due = true;
          w.lastTimeFireKey = key;
        }
      }
      if (!due) continue;
      if (!_governorAllows(w, now)) {
        _tripRunaway(w);
        continue;
      }
      _commitFire(w, client, now);
    }
  }

  // ── geofence triggers (location driven) ────────────────────────────

  /// Feed a GPS fix to the geo watchers. Called by the provider on each
  /// `currentLocationProvider` update (and directly by tests). Circle
  /// geofence with enter/exit hysteresis + dwell.
  void onLocation(double lat, double lng) {
    if (_disposed) return;
    final client = _client;
    if (client == null || _lastConn == DaemonState.disconnected) return;
    final now = _now();
    for (final w in _geoWatchers) {
      if (w.disabled) continue;
      final t = w.wf.trigger;
      if (t is! GeoTrigger) continue;
      final d = _distanceMeters(lat, lng, t.lat, t.lng);
      final was = w.geoInside;
      // Hysteresis: once inside, stay inside until beyond the exit radius.
      final inside = was == true ? d <= t.exitRadiusM : d <= t.enterRadiusM;
      w.geoInside = inside;

      var due = false;
      switch (t.event) {
        case WfGeoEvent.enter:
          due = was != true && inside;
        case WfGeoEvent.exit:
          due = was == true && !inside;
        case WfGeoEvent.dwell:
          if (inside) {
            w.geoDwellSince ??= now;
            if (!w.geoDwellFired &&
                now.difference(w.geoDwellSince!) >= t.dwell) {
              due = true;
              w.geoDwellFired = true;
            }
          } else {
            w.geoDwellSince = null;
            w.geoDwellFired = false;
          }
      }
      if (!due) continue;
      if (w.lastFire != null && now.difference(w.lastFire!) < t.cooldown) {
        continue;
      }
      if (!_governorAllows(w, now)) {
        _tripRunaway(w);
        continue;
      }
      _commitFire(w, client, now);
    }
  }

  /// Great-circle distance in metres (haversine).
  static double _distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthR = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _deg2rad(double d) => d * (math.pi / 180.0);

  /// Update the watcher's arm state for the edge mode; returns whether
  /// it is currently armed (fireable, before debounce/cooldown).
  bool _updateArm(
    _Watcher w,
    WfEdgeMode edge, {
    required bool? prev,
    required bool cur,
    required DateTime now,
  }) {
    switch (edge) {
      case WfEdgeMode.rising:
        if (prev != true && cur) {
          w.armedSince ??= now;
          w.firedForArm = false;
        } else if (!cur) {
          w.armedSince = null;
          w.firedForArm = false;
        }
        return cur && w.armedSince != null;
      case WfEdgeMode.falling:
        if (prev == true && !cur) {
          w.armedSince ??= now;
          w.firedForArm = false;
        } else if (cur) {
          w.armedSince = null;
          w.firedForArm = false;
        }
        return !cur && w.armedSince != null;
      case WfEdgeMode.both:
        final changed = prev != null && prev != cur;
        if (changed) {
          w.armedSince = now;
          w.firedForArm = false;
          return true;
        }
        return false;
      case WfEdgeMode.level:
        if (cur) {
          w.armedSince ??= now;
        } else {
          w.armedSince = null;
          w.firedForArm = false;
        }
        return cur;
    }
  }

  bool _governorAllows(_Watcher w, DateTime now) {
    final cutoff = now.subtract(kGovernorWindow);
    w.runHistory.removeWhere((t) => t.isBefore(cutoff));
    _globalRuns.removeWhere((t) => t.isBefore(cutoff));
    return w.runHistory.length < kMaxRunsPerWorkflowPerWindow &&
        _globalRuns.length < kMaxRunsGlobalPerWindow;
  }

  void _tripRunaway(_Watcher w) {
    w.disabled = true;
    debugPrint(
      '[workflow] runaway governor disabled "${w.wf.id}" (${w.wf.name})',
    );
  }

  // ── action execution (Macro abort-on-first-failure semantics) ──────

  Future<void> _run(_Watcher w, CarClient client) async {
    final wf = w.wf;
    List<CompiledAction> actions = wf.trueActions;
    if (wf.condition != null) {
      final c = wf.condition!;
      int? read(String s) => client.value(s);
      // Condition stale guard — fail closed: if ANY signal the condition
      // reads is stale/unknown, treat the whole condition as false.
      bool pass;
      if (c.staleGuard > Duration.zero) {
        final stale = c.signals.any((s) {
          final age = client.freshness(s);
          return age == null || age > c.staleGuard;
        });
        pass = !stale && c.evaluate(read);
      } else {
        pass = c.evaluate(read);
      }
      actions = pass ? wf.trueActions : wf.falseActions;
    }

    // Per-run variable scope: `set_var` writes here; later dispatchable
    // actions read `$name` args from it. Lifetime is THIS firing only —
    // no cross-firing/persistent state (no confusing reset-on-reboot).
    final vars = <String, num>{};
    for (final action in actions) {
      final outcome = await _runAction(wf, action, client, vars);
      if (outcome != WorkflowRunOutcome.fired) {
        // Macro semantics: abort the chain on the first non-fire.
        _lastOutcome = outcome;
        return;
      }
    }
    _lastOutcome = WorkflowRunOutcome.fired;
  }

  /// One-shot manual run for the canvas's "Test" button. Runs a DRAFT
  /// workflow once through the REAL action path (notify shows, apps
  /// launch, car commands go through the gated router) and returns a
  /// trace. The trigger is treated as already-fired (a manual start);
  /// the condition + every safety gate (stationary / security-confirm /
  /// consent) still apply, so the trace honestly reflects production.
  /// Does NOT arm the workflow or touch the live watcher set.
  Future<Map<String, Object?>> testRun(CompiledWorkflow wf) async {
    final client = _client;
    if (client == null) {
      return <String, Object?>{'ok': false, 'error': 'car not connected'};
    }
    bool? conditionPassed;
    List<CompiledAction> actions = wf.trueActions;
    if (wf.condition != null) {
      final c = wf.condition!;
      int? read(String s) => client.value(s);
      bool pass;
      if (c.staleGuard > Duration.zero) {
        final stale = c.signals.any((s) {
          final age = client.freshness(s);
          return age == null || age > c.staleGuard;
        });
        pass = !stale && c.evaluate(read);
      } else {
        pass = c.evaluate(read);
      }
      conditionPassed = pass;
      actions = pass ? wf.trueActions : wf.falseActions;
    }
    final steps = <Map<String, Object?>>[];
    final vars = <String, num>{};
    for (final action in actions) {
      final outcome = await _runAction(wf, action, client, vars);
      steps.add(<String, Object?>{
        'actionId': action.actionId,
        'type': action.type,
        'outcome': outcome.name,
      });
      if (outcome != WorkflowRunOutcome.fired) break; // macro abort
    }
    return <String, Object?>{
      'ok': true,
      'conditionPassed': conditionPassed,
      'steps': steps,
    };
  }

  Future<WorkflowRunOutcome> _runAction(
    CompiledWorkflow wf,
    CompiledAction action,
    CarClient client,
    Map<String, num> vars,
  ) async {
    // Import consent wall (plan §8/§12) — an imported (shared-template)
    // workflow refuses every consent-gated action until the owner approved
    // its id in-car. Authored workflows pass this unconditionally.
    if (!wf.isConsented(action)) {
      debugPrint(
        '[workflow] "${wf.id}" ${action.actionId} not consented (imported)',
      );
      return WorkflowRunOutcome.notConsented;
    }

    // Engine-level stationary gate — INDEPENDENT of the per-command
    // flag. Any safety/security-class action is blocked for a moving
    // car when fired by a background trigger.
    if (action.gatedWhileMoving) {
      final speed = await _readSpeed(client);
      if (speed != null && speed > kEngineStationarySpeedLimit) {
        debugPrint(
          '[workflow] "${wf.id}" blocked ${action.actionId}: moving (${speed}km/h)',
        );
        return WorkflowRunOutcome.blockedWhileMoving;
      }
    }
    // Security-class actions need explicit pre-consent for a background
    // trigger.
    if (action.requiresConfirm && !wf.autoConfirm) {
      debugPrint(
        '[workflow] "${wf.id}" needs confirm for ${action.actionId}; not auto-running',
      );
      return WorkflowRunOutcome.needsConfirm;
    }

    // Engine-local `delay` — pause the chain, then re-check liveness so a
    // dispose/reload during the wait aborts the rest of the chain cleanly.
    // CRITICAL: also verify the bound client is STILL the one we started
    // with — a brand re-resolve (bindClient) during the wait swaps
    // `_client`, and the rest of this chain holds the OLD `client`. Firing
    // a post-delay command against a stale client would target the wrong
    // car, so abort instead (same lifecycle discipline as the rebind fix).
    if (action.type == 'delay') {
      final ms = (action.args['ms'] as num?)?.toInt() ?? 0;
      if (ms > 0) await _delay(Duration(milliseconds: ms));
      if (_disposed || _client == null || !identical(client, _client)) {
        return WorkflowRunOutcome.suppressed;
      }
      return WorkflowRunOutcome.fired;
    }

    // Engine-local `set_var` — evaluate the expression over signals +
    // prior vars and store it. An unresolvable expression (stale signal,
    // unknown var, /0) leaves the var unset but does NOT abort the chain.
    if (action.type == 'set_var') {
      final value = action.expr?.eval(
        (token) => token.startsWith(r'$')
            ? vars[token.substring(1)]
            : client.value(token),
      );
      if (value != null && action.varName != null) {
        vars[action.varName!] = value;
      }
      return WorkflowRunOutcome.fired;
    }

    // Interpolate any `$name` args from the run's variable scope (set by
    // a preceding `set_var`) — uniformly across EVERY dispatchable action
    // so `$x` resolves the same way regardless of action type.
    final args = _interpolateArgs(action.args, vars);

    // Route by action type. Radio/app/notify go to their subsystems
    // (injected); everything else (car_command) through the gated
    // CarCommandRouter.
    final Map<String, Object?> result;
    switch (action.type) {
      case 'radio':
        if (_dispatchRadio == null) return WorkflowRunOutcome.dispatchFailed;
        result = await _dispatchRadio(action.actionId, args);
      case 'app':
        if (_dispatchApp == null) return WorkflowRunOutcome.dispatchFailed;
        result = await _dispatchApp(action.actionId, args);
      case 'notify':
        if (_dispatchNotify == null) return WorkflowRunOutcome.dispatchFailed;
        // Imported (shared-template) workflows may post IN-APP ONLY —
        // never the system notification shade — so a hostile template
        // can't mimic a system / ownership-verification prompt in the OS
        // shade (review: notify-phishing finding).
        final notifyArgs = wf.source == 'imported'
            ? {...args, 'target': 'inapp'}
            : args;
        result = await _dispatchNotify(action.actionId, notifyArgs);
      case 'cluster':
        if (_dispatchCluster == null) return WorkflowRunOutcome.dispatchFailed;
        result = await _dispatchCluster(action.actionId, args);
      default:
        result = await client.dispatch(
          action.actionId,
          args: args,
          caller: AutomationConsumer(workflowId: wf.id),
        );
    }
    if (result['error'] != null) {
      return WorkflowRunOutcome.dispatchFailed;
    }
    return WorkflowRunOutcome.fired;
  }

  /// Replace any `$name` string arg with its run-variable value. A `$name`
  /// with no matching variable is left verbatim (fail-soft — the command
  /// layer validates its own args). Returns [args] unchanged when there
  /// are no variables (the common case — zero allocation).
  static Map<String, Object?> _interpolateArgs(
    Map<String, Object?> args,
    Map<String, num> vars,
  ) {
    if (vars.isEmpty || args.isEmpty) return args;
    final out = <String, Object?>{};
    args.forEach((k, v) {
      if (v is String && v.startsWith(r'$')) {
        final name = v.substring(1);
        out[k] = vars.containsKey(name) ? vars[name] : v;
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  void dispose() {
    _disposed = true;
    _changesSub?.cancel();
    _connSub?.cancel();
    _timeTimer?.cancel();
    _timeTimer = null;
    _watchers.clear();
    _byTriggerSignal.clear();
    _timeWatchers.clear();
    _geoWatchers.clear();
  }

  // ── test surface ───────────────────────────────────────────────────

  /// Await any in-flight action runs. Tests call this after pushing a
  /// frame to observe the dispatch outcome deterministically.
  /// Drive the wall-clock evaluation deterministically in tests (the
  /// production ticker calls `_onTimeTick(_now())` every ~20 s).
  @visibleForTesting
  void tickTime(DateTime now) => _onTimeTick(now);

  @visibleForTesting
  Future<void> drain() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(List<Future<void>>.from(_inFlight));
    }
  }

  @visibleForTesting
  int runCountFor(String workflowId) =>
      _watchers[workflowId]?.runHistory.length ?? 0;

  @visibleForTesting
  bool isDisabled(String workflowId) =>
      _watchers[workflowId]?.disabled ?? false;

  @visibleForTesting
  bool get isArmed => _changesSub != null;

  @visibleForTesting
  WorkflowRunOutcome? get lastOutcome => _lastOutcome;
  WorkflowRunOutcome? _lastOutcome;
}
