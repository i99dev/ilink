import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/engine/compiled_workflow.dart';
import 'package:ilink/features/workflow/engine/workflow_engine.dart';
import 'package:ilink/sdk/car/car_caller.dart';
import 'package:ilink/sdk/car/client.dart';

/// A minimal in-memory [CarClient] for the engine. Implements only the
/// handful of members the engine touches; `noSuchMethod` covers the
/// rest (they're never called).
class FakeCarClient implements CarClient {
  final _changes = StreamController<String>.broadcast();
  final _conn = StreamController<DaemonState>.broadcast();
  final Map<String, int?> _values = {};
  final Map<String, Duration> _ages = {};

  /// Recorded dispatches (the engine's only side effect).
  final List<String> dispatched = [];

  /// Recorded args for the most recent dispatch of each actionId — lets
  /// tests assert `$var` interpolation reached the command layer.
  final Map<String, Map<String, Object?>> dispatchedArgs = {};

  DaemonState _connState = DaemonState.connected;
  Map<String, Object?> Function(String actionId)? onDispatch;

  /// Set a value WITHOUT emitting a change frame (seed state).
  void seed(String name, int? value) {
    _values[name] = value;
    _ages[name] = Duration.zero;
  }

  /// Override the reported freshness of a name (for stale-guard tests).
  void seedAge(String name, Duration age) {
    _ages[name] = age;
  }

  /// Set a value AND emit a change frame for it.
  void push(String name, int? value) {
    seed(name, value);
    _changes.add(name);
  }

  void emitConnection(DaemonState state) {
    _connState = state;
    _conn.add(state);
  }

  @override
  int? value(String name) => _values[name];

  @override
  Duration? freshness(String name) => _ages[name];

  @override
  Stream<String> changes() => _changes.stream;

  @override
  Stream<DaemonState> connectionState() => _conn.stream;

  @override
  DaemonState get currentConnectionState => _connState;

  @override
  Future<Map<String, Object?>> dispatch(
    String actionId, {
    Map<String, Object?> args = const {},
    CarCaller? caller,
  }) async {
    final result = onDispatch?.call(actionId) ?? {'ok': true};
    if (result['error'] == null) {
      dispatched.add(actionId);
      dispatchedArgs[actionId] = args;
    }
    return result;
  }

  void dispose() {
    _changes.close();
    _conn.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Build a Phase-A document: threshold trigger → optional condition →
/// one car_command action.
Map<String, Object?> doc({
  required String id,
  required String signal,
  required String op,
  required num value,
  String edge = 'rising',
  int debounceMs = 0,
  int cooldownMs = 0,
  int staleGuardMs = 0,
  String actionId = 'climate.power.on',
  String securityClass = 'none',
  String actionType = 'car_command',
  String triggerType = 'signal.threshold',
  String from = '>5',
  String to = '==0',
  int everyMin = 30,
  String at = '07:30',
  List<int> days = const [],
  double geoLat = 25.0,
  double geoLng = 55.0,
  num radiusM = 150,
  int dwellSec = 120,
  ({String signal, String op, num value})? condition,
  bool autoConfirm = false,
}) {
  final nodes = <Map<String, Object?>>[
    {
      'id': 'trg',
      'kind': 'trigger',
      'type': triggerType,
      'config': switch (triggerType) {
        'signal.transition' => {'name': signal, 'from': from, 'to': to},
        'signal.changed' => {'name': signal},
        'time.interval' => {'everyMin': everyMin},
        'time.at' => {'hhmm': at, 'daysOfWeek': days},
        'geo.enter' || 'geo.exit' => {
          'shape': 'circle',
          'lat': geoLat,
          'lng': geoLng,
          'radiusM': radiusM,
        },
        'geo.dwell' => {
          'shape': 'circle',
          'lat': geoLat,
          'lng': geoLng,
          'radiusM': radiusM,
          'dwellSec': dwellSec,
        },
        _ => {'name': signal, 'op': op, 'value': value},
      },
      'edge': edge,
      'debounceMs': debounceMs,
      'cooldownMs': cooldownMs,
      'staleGuardMs': staleGuardMs,
    },
  ];
  final edges = <Map<String, Object?>>[];
  if (condition != null) {
    nodes.add({
      'id': 'cnd',
      'kind': 'condition',
      'type': 'signal_compare',
      'config': {
        'signal': condition.signal,
        'op': condition.op,
        'value': condition.value,
      },
    });
    nodes.add({
      'id': 'act',
      'kind': 'action',
      'type': actionType,
      'config': {'actionId': actionId},
      'flags': {'securityClass': securityClass},
    });
    edges.add({'from': 'trg', 'to': 'cnd'});
    edges.add({'from': 'cnd', 'to': 'act', 'when': 'true'});
  } else {
    nodes.add({
      'id': 'act',
      'kind': 'action',
      'type': actionType,
      'config': {'actionId': actionId},
      'flags': {'securityClass': securityClass},
    });
    edges.add({'from': 'trg', 'to': 'act'});
  }
  return {
    'workflowId': id,
    'name': id,
    'autoConfirm': autoConfirm,
    'nodes': nodes,
    'edges': edges,
  };
}

CompiledWorkflow compile(Map<String, Object?> d) {
  final r = compileWorkflowDocument(d);
  expect(r.ok, isTrue, reason: r.error);
  return r.workflow!;
}

/// A voice.phrase → car_command document (securityClass none, so it isn't
/// stationary-gated in the fire tests).
Map<String, Object?> voiceDoc(
  String id,
  String phrase, {
  List<String> examples = const [],
}) => {
  'workflowId': id,
  'name': id,
  'nodes': [
    {
      'id': 'trg',
      'kind': 'trigger',
      'type': 'voice.phrase',
      'config': {'phrase': phrase, 'examples': examples},
    },
    {
      'id': 'act',
      'kind': 'action',
      'type': 'car_command',
      'config': {'actionId': 'climate.power.on'},
      'flags': {'securityClass': 'none'},
    },
  ],
  'edges': [
    {'from': 'trg', 'to': 'act'},
  ],
};

void main() {
  group('compileWorkflowDocument (fail-closed)', () {
    test('compiles a canonical threshold→action document', () {
      final wf = compile(
        doc(id: 'wf_a', signal: 'battery_pct', op: '<', value: 20),
      );
      expect((wf.trigger as SignalTrigger).signal, 'battery_pct');
      expect(wf.trueActions.single.actionId, 'climate.power.on');
      expect(wf.condition, isNull);
    });

    test('rejects an unknown node kind (fail-closed)', () {
      final d = doc(id: 'wf_c', signal: 'x', op: '>', value: 0);
      (d['nodes'] as List).add({'id': 'zz', 'kind': 'wormhole', 'config': {}});
      final r = compileWorkflowDocument(d);
      expect(r.ok, isFalse);
      expect(r.error, contains('unknown node kind'));
    });

    test('rejects an unsupported trigger type', () {
      final d = doc(id: 'wf_t', signal: 'x', op: '>', value: 0);
      (d['nodes'] as List)[0]['type'] = 'geo.enter';
      expect(compileWorkflowDocument(d).ok, isFalse);
    });

    test('clamps an over-long delay to the engine ceiling', () {
      final d = <String, Object?>{
        'workflowId': 'wf_clamp',
        'name': 'clamp',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'b', 'op': '<', 'value': 20},
          },
          {
            'id': 'w',
            'kind': 'action',
            'type': 'delay',
            'config': {'ms': 86400000}, // 24h — the SDK schema max
          },
        ],
        'edges': [
          {'from': 't', 'to': 'w'},
        ],
      };
      final wf = compile(d);
      expect(wf.trueActions.first.type, 'delay');
      expect(wf.trueActions.first.args['ms'], kMaxWorkflowDelayMs);
    });
  });

  group('WorkflowEngine', () {
    late FakeCarClient client;
    late WorkflowEngine engine;
    late List<String> radioCalls;
    late List<String> appCalls;
    late List<String> clusterCalls;
    late List<Map<String, Object?>> clusterArgs;
    late List<Map<String, Object?>> notifyCalls;
    late List<Duration> delays;
    DateTime clock = DateTime(2026, 1, 1, 12, 0, 0);
    int? speed = 0;

    setUp(() {
      clock = DateTime(2026, 1, 1, 12, 0, 0);
      speed = 0;
      radioCalls = [];
      appCalls = [];
      clusterCalls = [];
      clusterArgs = [];
      notifyCalls = [];
      delays = [];
      client = FakeCarClient();
      engine = WorkflowEngine(
        clock: () => clock,
        speedReader: (_) async => speed,
        // Record the requested wait, then return instantly so chain
        // ordering is observable without real wall-clock time.
        delay: (d) async => delays.add(d),
        dispatchRadio: (id, args) async {
          radioCalls.add(id);
          return {'ok': true};
        },
        dispatchApp: (id, args) async {
          appCalls.add(id);
          return {'ok': true};
        },
        dispatchCluster: (route, args) async {
          clusterCalls.add(route);
          clusterArgs.add(args);
          return {'ok': true};
        },
        dispatchNotify: (id, args) async {
          notifyCalls.add(args);
          return {'ok': true};
        },
      );
    });

    tearDown(() {
      engine.dispose();
      client.dispose();
    });

    Future<void> tick() async {
      await pumpEventQueue();
      await engine.drain();
    }

    test(
      'rising edge fires once, then again only after the predicate resets',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(doc(id: 'w', signal: 'battery_pct', op: '<', value: 20)),
        ]);

        client.push('battery_pct', 19); // false→true: fire
        await tick();
        client.push('battery_pct', 18); // stays true: no re-fire
        await tick();
        expect(client.dispatched, ['climate.power.on']);

        client.push('battery_pct', 25); // true→false: disarm
        await tick();
        client.push('battery_pct', 15); // false→true: fire again
        await tick();
        expect(client.dispatched, ['climate.power.on', 'climate.power.on']);
      },
    );

    test(
      'signal.changed fires on any value change (not on a repeat)',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'gear',
              op: '==',
              value: 0,
              triggerType: 'signal.changed',
            ),
          ),
        ]);
        client.push('gear', 1); // first value seen (prev null) → no fire
        await tick();
        expect(client.dispatched, isEmpty);
        client.push('gear', 2); // changed → fire
        await tick();
        client.push('gear', 2); // same value → no fire
        await tick();
        expect(client.dispatched, ['climate.power.on']);
      },
    );

    test(
      'voice.phrase fires on a matching utterance (workflow wins)',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(voiceDoc('w', 'movie time', examples: ['cinema mode'])),
        ]);
        // The phrase set feeds the Vosk grammar (single source of truth).
        expect(
          engine.activeVoicePhrases(),
          containsAll(['movie time', 'cinema mode']),
        );

        // Non-matching utterance → no fire, reports no match (null).
        expect(engine.onVoicePhrase('open the window'), isNull);
        await tick();
        expect(client.dispatched, isEmpty);

        // Matching (with an un-stripped leading wake word) → fires + returns
        // the automation NAME so the controller can suppress a built-in
        // command for the same words and name it in the feedback chip.
        expect(engine.onVoicePhrase('hey byd movie time'), 'w');
        await tick();
        expect(client.dispatched, ['climate.power.on']);

        // An example phrase also fires.
        expect(engine.onVoicePhrase('cinema mode'), 'w');
        await tick();
        expect(client.dispatched, ['climate.power.on', 'climate.power.on']);

        // Whole-word run, not substring: an utterance that merely shares a
        // word ("time") with a phrase ("movie time") does NOT over-fire.
        expect(engine.onVoicePhrase('what time is it'), isNull);
        // Trailing politeness still matches (word-run anywhere).
        expect(engine.onVoicePhrase('movie time please'), 'w');
      },
    );

    test('signal.transition fires only on the from→to crossing', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(
            id: 'w',
            signal: 'speed_kmh',
            op: '==',
            value: 0,
            triggerType: 'signal.transition',
            from: '>5',
            to: '==0',
          ),
        ),
      ]);
      client.push('speed_kmh', 30); // matches `from`, not `to` → no fire
      await tick();
      expect(client.dispatched, isEmpty);
      client.push('speed_kmh', 0); // 30(>5) → 0(==0) → fire ("just parked")
      await tick();
      expect(client.dispatched, ['climate.power.on']);
      client.push('speed_kmh', 0); // still 0, no crossing → no fire
      await tick();
      expect(client.dispatched, ['climate.power.on']);
    });

    test(
      'routes a radio action to the radio dispatcher, not the car router',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'b',
              op: '<',
              value: 20,
              actionType: 'radio',
              actionId: 'radio.play_by_name',
            ),
          ),
        ]);
        client.push('b', 10);
        await tick();
        expect(radioCalls, ['radio.play_by_name']);
        expect(client.dispatched, isEmpty);
      },
    );

    test('routes an app action to the app dispatcher', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(
            id: 'w',
            signal: 'b',
            op: '<',
            value: 20,
            actionType: 'app',
            actionId: 'app.open',
          ),
        ),
      ]);
      client.push('b', 10);
      await tick();
      expect(appCalls, ['app.open']);
      expect(client.dispatched, isEmpty);
    });

    Map<String, Object?> importedDoc({
      required String actionId,
      List<String> consented = const [],
      String actionType = 'car_command',
    }) => {
      'workflowId': 'wf_imp',
      'name': 'imported',
      'source': 'imported',
      'consentedActions': consented,
      'nodes': [
        {
          'id': 't',
          'kind': 'trigger',
          'type': 'signal.threshold',
          'config': {'name': 'b', 'op': '<', 'value': 20},
        },
        {
          'id': 'a',
          'kind': 'action',
          'type': actionType,
          'config': {'actionId': actionId},
          'flags': {'securityClass': 'none'},
        },
      ],
      'edges': [
        {'from': 't', 'to': 'a'},
      ],
    };

    test(
      'imported workflow refuses a consent-gated action until it is consented',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(importedDoc(actionId: 'climate.power.on')), // no consent
        ]);
        client.push('b', 10);
        await tick();
        expect(client.dispatched, isEmpty);
        expect(engine.lastOutcome, WorkflowRunOutcome.notConsented);
      },
    );

    test('imported workflow runs an action once its id is consented', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          importedDoc(
            actionId: 'climate.power.on',
            consented: ['climate.power.on'],
          ),
        ),
      ]);
      client.push('b', 10);
      await tick();
      expect(client.dispatched, ['climate.power.on']);
    });

    test('imported workflow runs a benign notify without consent', () async {
      engine.bindClient(client);
      final d = importedDoc(actionId: 'notify', actionType: 'notify');
      (d['nodes'] as List)[1]['config'] = {'title': 'hi'};
      engine.loadWorkflows([compile(d)]);
      client.push('b', 10);
      await tick();
      expect(notifyCalls, hasLength(1)); // no consent needed for notify
    });

    test('set_var computes a value that a later action interpolates', () async {
      engine.bindClient(client);
      final d = <String, Object?>{
        'workflowId': 'wf_var',
        'name': 'var',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'ambient_lux', 'op': '<', 'value': 1000},
          },
          {
            'id': 'sv',
            'kind': 'action',
            'type': 'set_var',
            'config': {'name': 'level', 'expr': 'ambient_lux / 100'},
          },
          {
            'id': 'a',
            'kind': 'action',
            'type': 'car_command',
            'config': {
              'actionId': 'light.brightness',
              'args': {'level': r'$level'},
            },
            'flags': {'securityClass': 'none'},
          },
        ],
        'edges': [
          {'from': 't', 'to': 'sv'},
          {'from': 'sv', 'to': 'a'},
        ],
      };
      engine.loadWorkflows([compile(d)]);
      client.seed('ambient_lux', 800);
      client.push('ambient_lux', 800); // rising edge (<1000)
      await tick();
      expect(client.dispatched, ['light.brightness']);
      // 800 / 100 = 8 — the $level arg was interpolated.
      expect(client.dispatchedArgs['light.brightness']?['level'], 8);
    });

    test('set_var with an unresolvable expr leaves the arg uninterpolated '
        'but does not abort the chain', () async {
      engine.bindClient(client);
      final d = <String, Object?>{
        'workflowId': 'wf_var2',
        'name': 'var2',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'b', 'op': '<', 'value': 20},
          },
          {
            'id': 'sv',
            'kind': 'action',
            'type': 'set_var',
            'config': {'name': 'x', 'expr': 'nonexistent_signal + 1'},
          },
          {
            'id': 'a',
            'kind': 'action',
            'type': 'car_command',
            'config': {
              'actionId': 'climate.power.on',
              'args': {'temp': r'$x'},
            },
            'flags': {'securityClass': 'none'},
          },
        ],
        'edges': [
          {'from': 't', 'to': 'sv'},
          {'from': 'sv', 'to': 'a'},
        ],
      };
      engine.loadWorkflows([compile(d)]);
      client.push('b', 10);
      await tick();
      // Chain still runs; the unresolved $x is passed through verbatim.
      expect(client.dispatched, ['climate.power.on']);
      expect(client.dispatchedArgs['climate.power.on']?['temp'], r'$x');
    });

    test(
      'REGRESSION: delay aborts the chain if the client is re-bound mid-wait',
      () async {
        // A brand re-resolve DURING a delay swaps the engine's client; the
        // rest of the chain must NOT dispatch to the stale captured client.
        final clientB = FakeCarClient();
        late WorkflowEngine eng;
        eng = WorkflowEngine(
          clock: () => clock,
          speedReader: (_) async => 0,
          delay: (_) async => eng.bindClient(clientB), // rebind mid-wait
        );
        eng.bindClient(client);
        final d = <String, Object?>{
          'workflowId': 'wf_sc',
          'name': 'sc',
          'nodes': [
            {
              'id': 't',
              'kind': 'trigger',
              'type': 'signal.threshold',
              'config': {'name': 'b', 'op': '<', 'value': 20},
            },
            {
              'id': 'wait',
              'kind': 'action',
              'type': 'delay',
              'config': {'ms': 1000},
            },
            {
              'id': 'a',
              'kind': 'action',
              'type': 'car_command',
              'config': {'actionId': 'climate.power.on'},
              'flags': {'securityClass': 'none'},
            },
          ],
          'edges': [
            {'from': 't', 'to': 'wait'},
            {'from': 'wait', 'to': 'a'},
          ],
        };
        eng.loadWorkflows([compile(d)]);
        client.push('b', 10);
        await pumpEventQueue();
        await eng.drain();
        expect(
          client.dispatched,
          isEmpty,
          reason: 'stale client must not fire',
        );
        expect(
          clientB.dispatched,
          isEmpty,
          reason: 'chain aborted, not re-run',
        );
        expect(eng.lastOutcome, WorkflowRunOutcome.suppressed);
        eng.dispose();
        clientB.dispose();
      },
    );

    test(
      'imported workflow forces notify to in-app (no system shade)',
      () async {
        engine.bindClient(client);
        final d = importedDoc(actionId: 'notify', actionType: 'notify');
        (d['nodes'] as List)[1]['config'] = {'title': 'hi', 'target': 'system'};
        engine.loadWorkflows([compile(d)]);
        client.push('b', 10);
        await tick();
        expect(
          notifyCalls.single['target'],
          'inapp',
          reason: 'imported notify must not reach the system shade',
        );
      },
    );

    test('cluster output interpolates a \$var arg', () async {
      engine.bindClient(client);
      final d = <String, Object?>{
        'workflowId': 'wf_ci',
        'name': 'ci',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'b', 'op': '<', 'value': 20},
          },
          {
            'id': 'sv',
            'kind': 'action',
            'type': 'set_var',
            'config': {'name': 'ttl', 'expr': '1000'},
          },
          {
            'id': 'c',
            'kind': 'cluster_output',
            'config': {'route': '/x', 'mode': 'transient', 'ttlMs': r'$ttl'},
          },
        ],
        'edges': [
          {'from': 't', 'to': 'sv'},
          {'from': 'sv', 'to': 'c'},
        ],
      };
      engine.loadWorkflows([compile(d)]);
      client.push('b', 10);
      await tick();
      expect(clusterArgs.single['ttlMs'], 1000); // $ttl interpolated
    });

    test('cooldown suppresses a re-fire until the window elapses', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(id: 'w', signal: 'b', op: '<', value: 20, cooldownMs: 60000),
        ),
      ]);
      client.push('b', 10);
      await tick();
      expect(client.dispatched.length, 1);

      client.push('b', 30); // reset
      await tick();
      clock = clock.add(const Duration(seconds: 30)); // still inside cooldown
      client.push('b', 10);
      await tick();
      expect(client.dispatched.length, 1, reason: 'cooldown should suppress');

      client.push('b', 30);
      await tick();
      clock = clock.add(const Duration(seconds: 61)); // past cooldown
      client.push('b', 10);
      await tick();
      expect(client.dispatched.length, 2);
    });

    test(
      'engine stationary gate blocks a safety-class action while moving',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'b',
              op: '<',
              value: 20,
              actionId: 'window.fl.close',
              securityClass: 'safety',
            ),
          ),
        ]);

        speed = 30; // moving
        client.push('b', 10);
        await tick();
        expect(client.dispatched, isEmpty);
        expect(engine.lastOutcome, WorkflowRunOutcome.blockedWhileMoving);

        speed = 0; // stopped
        client.push('b', 30); // reset edge
        await tick();
        client.push('b', 10);
        await tick();
        expect(client.dispatched, ['window.fl.close']);
      },
    );

    test(
      'security-class action needs confirm; not auto-run without autoConfirm',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'b',
              op: '<',
              value: 20,
              actionId: 'door.unlock',
              securityClass: 'security',
            ),
          ),
        ]);
        client.push('b', 10);
        await tick();
        expect(client.dispatched, isEmpty);
        expect(engine.lastOutcome, WorkflowRunOutcome.needsConfirm);
      },
    );

    test('condition gates the action branch', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(
            id: 'w',
            signal: 'b',
            op: '<',
            value: 20,
            condition: (signal: 'speed_kmh', op: '==', value: 0),
          ),
        ),
      ]);

      client.seed('speed_kmh', 10); // moving → condition false
      client.push('b', 10);
      await tick();
      expect(client.dispatched, isEmpty);

      client.push('b', 30); // reset
      await tick();
      client.seed('speed_kmh', 0); // parked → condition true
      client.push('b', 10);
      await tick();
      expect(client.dispatched, ['climate.power.on']);
    });

    test('routes a cluster_output node to the cluster renderer', () async {
      engine.bindClient(client);
      final d = <String, Object?>{
        'workflowId': 'wf_cl',
        'name': 'cl',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'b', 'op': '<', 'value': 20},
          },
          {
            'id': 'c',
            'kind': 'cluster_output',
            'config': {'route': '/wf.html', 'mode': 'transient', 'ttlMs': 5000},
          },
        ],
        'edges': [
          {'from': 't', 'to': 'c'},
        ],
      };
      engine.loadWorkflows([compile(d)]);
      client.push('b', 10);
      await tick();
      expect(clusterCalls, ['/wf.html']);
      expect(client.dispatched, isEmpty);
    });

    test('notify action routes to the notify dispatcher', () async {
      engine.bindClient(client);
      final d = <String, Object?>{
        'workflowId': 'wf_n',
        'name': 'n',
        'nodes': [
          {
            'id': 't',
            'kind': 'trigger',
            'type': 'signal.threshold',
            'config': {'name': 'b', 'op': '<', 'value': 20},
          },
          {
            'id': 'a',
            'kind': 'action',
            'type': 'notify',
            'config': {'title': 'Low battery', 'body': 'Plug in soon'},
          },
        ],
        'edges': [
          {'from': 't', 'to': 'a'},
        ],
      };
      engine.loadWorkflows([compile(d)]);
      client.push('b', 10);
      await tick();
      expect(notifyCalls, hasLength(1));
      expect(notifyCalls.single['title'], 'Low battery');
      expect(notifyCalls.single['body'], 'Plug in soon');
      expect(client.dispatched, isEmpty);
    });

    test(
      'delay waits the configured time, THEN runs the next chain step',
      () async {
        engine.bindClient(client);
        final d = <String, Object?>{
          'workflowId': 'wf_d',
          'name': 'd',
          'nodes': [
            {
              'id': 't',
              'kind': 'trigger',
              'type': 'signal.threshold',
              'config': {'name': 'b', 'op': '<', 'value': 20},
            },
            {
              'id': 'wait',
              'kind': 'action',
              'type': 'delay',
              'config': {'ms': 5000},
            },
            {
              'id': 'a',
              'kind': 'action',
              'type': 'car_command',
              'config': {'actionId': 'climate.power.on'},
              'flags': {'securityClass': 'none'},
            },
          ],
          'edges': [
            {'from': 't', 'to': 'wait'},
            {'from': 'wait', 'to': 'a'},
          ],
        };
        engine.loadWorkflows([compile(d)]);
        client.push('b', 10);
        await tick();
        expect(delays, [const Duration(milliseconds: 5000)]);
        expect(client.dispatched, ['climate.power.on']);
      },
    );

    test(
      'delay re-checks the stationary gate at the post-delay action',
      () async {
        engine.bindClient(client);
        final d = <String, Object?>{
          'workflowId': 'wf_dg',
          'name': 'dg',
          'nodes': [
            {
              'id': 't',
              'kind': 'trigger',
              'type': 'signal.threshold',
              'config': {'name': 'b', 'op': '<', 'value': 20},
            },
            {
              'id': 'wait',
              'kind': 'action',
              'type': 'delay',
              'config': {'ms': 1000},
            },
            {
              'id': 'a',
              'kind': 'action',
              'type': 'car_command',
              'config': {'actionId': 'window.fl.close'},
              'flags': {'securityClass': 'safety'},
            },
          ],
          'edges': [
            {'from': 't', 'to': 'wait'},
            {'from': 'wait', 'to': 'a'},
          ],
        };
        engine.loadWorkflows([compile(d)]);
        speed = 40; // moving when the post-delay safety action runs
        client.push('b', 10);
        await tick();
        expect(delays, [const Duration(milliseconds: 1000)]);
        expect(
          client.dispatched,
          isEmpty,
          reason: 'safety action gated after the delay while moving',
        );
        expect(engine.lastOutcome, WorkflowRunOutcome.blockedWhileMoving);
      },
    );

    test(
      'geo.enter fires on outside→inside crossing (with hysteresis)',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'x',
              op: '<',
              value: 1,
              triggerType: 'geo.enter',
              geoLat: 25.0,
              geoLng: 55.0,
              radiusM: 150,
            ),
          ),
        ]);
        engine.onLocation(25.1, 55.0); // ~11 km away — outside
        await engine.drain();
        expect(client.dispatched, isEmpty);
        engine.onLocation(25.0, 55.0); // at the centre — enter → fire
        await engine.drain();
        engine.onLocation(25.0, 55.0); // still inside — no re-fire
        await engine.drain();
        expect(client.dispatched, ['climate.power.on']);
        engine.onLocation(25.1, 55.0); // leave (no fire — that's exit)
        await engine.drain();
        engine.onLocation(25.0, 55.0); // re-enter → fire again
        await engine.drain();
        expect(client.dispatched, ['climate.power.on', 'climate.power.on']);
      },
    );

    test('geo.dwell fires after continuous time inside', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(
            id: 'w',
            signal: 'x',
            op: '<',
            value: 1,
            triggerType: 'geo.dwell',
            geoLat: 25.0,
            geoLng: 55.0,
            radiusM: 150,
            dwellSec: 120,
          ),
        ),
      ]);
      clock = DateTime(2026, 1, 1, 12, 0, 0);
      engine.onLocation(25.0, 55.0); // enter — dwell clock starts, not elapsed
      await engine.drain();
      expect(client.dispatched, isEmpty);
      clock = DateTime(2026, 1, 1, 12, 3, 0); // +3 min ≥ 120 s
      engine.onLocation(25.0, 55.0); // still inside, dwell elapsed → fire
      await engine.drain();
      engine.onLocation(25.0, 55.0); // still inside — no re-fire this dwell
      await engine.drain();
      expect(client.dispatched, ['climate.power.on']);
    });

    test(
      'geo.exit fires on inside→outside, and membership SURVIVES a reload',
      () async {
        engine.bindClient(client);
        CompiledWorkflow exitWf() => compile(
          doc(
            id: 'w',
            signal: 'x',
            op: '<',
            value: 1,
            triggerType: 'geo.exit',
            geoLat: 25.0,
            geoLng: 55.0,
            radiusM: 150,
          ),
        );
        engine.loadWorkflows([exitWf()]);
        engine.onLocation(25.0, 55.0); // inside — establishes "was inside"
        await engine.drain();
        expect(client.dispatched, isEmpty); // exit doesn't fire on entry
        // An /account re-sync rebuilds every watcher mid-journey. Without
        // state migration this resets geoInside=null and the exit below is
        // silently lost — the reported "leave area doesn't fire" bug.
        engine.loadWorkflows([exitWf()]);
        engine.onLocation(25.2, 55.0); // ~22 km away — leave → exit fires
        await engine.drain();
        expect(client.dispatched, ['climate.power.on']);
      },
    );

    test(
      'time.interval fires every N minutes (anchored, not immediately)',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'x',
              op: '<',
              value: 1,
              triggerType: 'time.interval',
              everyMin: 30,
            ),
          ),
        ]);
        engine.tickTime(DateTime(2026, 1, 1, 12, 0)); // anchor tick — no fire
        await engine.drain();
        engine.tickTime(DateTime(2026, 1, 1, 12, 20)); // 20 min < 30
        await engine.drain();
        expect(client.dispatched, isEmpty);
        engine.tickTime(DateTime(2026, 1, 1, 12, 31)); // 31 min ≥ 30 → fire
        await engine.drain();
        expect(client.dispatched, ['climate.power.on']);
      },
    );

    test(
      'time.at fires once at HH:MM, again next day, never on a repeat tick',
      () async {
        engine.bindClient(client);
        engine.loadWorkflows([
          compile(
            doc(
              id: 'w',
              signal: 'x',
              op: '<',
              value: 1,
              triggerType: 'time.at',
              at: '07:30',
            ),
          ),
        ]);
        engine.tickTime(DateTime(2026, 1, 1, 7, 29)); // before
        await engine.drain();
        expect(client.dispatched, isEmpty);
        engine.tickTime(DateTime(2026, 1, 1, 7, 30)); // match → fire
        await engine.drain();
        engine.tickTime(
          DateTime(2026, 1, 1, 7, 30),
        ); // same occurrence → no re-fire
        await engine.drain();
        expect(client.dispatched, ['climate.power.on']);
        engine.tickTime(DateTime(2026, 1, 2, 7, 30)); // next day → fire again
        await engine.drain();
        expect(client.dispatched, ['climate.power.on', 'climate.power.on']);
      },
    );

    test(
      'logic_group AND requires every rule (else the true-branch is skipped)',
      () async {
        engine.bindClient(client);
        final docMap = <String, Object?>{
          'workflowId': 'wf_g',
          'name': 'g',
          'nodes': [
            {
              'id': 't',
              'kind': 'trigger',
              'type': 'signal.threshold',
              'config': {'name': 'b', 'op': '<', 'value': 20},
            },
            {
              'id': 'c',
              'kind': 'condition',
              'type': 'logic_group',
              'config': {
                'op': 'and',
                'rules': [
                  {'signal': 'speed_kmh', 'op': '==', 'value': 0},
                  {'signal': 'gear', 'op': '==', 'value': 1},
                ],
              },
            },
            {
              'id': 'a',
              'kind': 'action',
              'type': 'car_command',
              'config': {'actionId': 'climate.power.on'},
              'flags': {'securityClass': 'none'},
            },
          ],
          'edges': [
            {'from': 't', 'to': 'c'},
            {'from': 'c', 'to': 'a', 'when': 'true'},
          ],
        };
        engine.loadWorkflows([compile(docMap)]);

        client.seed('speed_kmh', 0);
        client.seed('gear', 1); // both rules true
        client.push('b', 10);
        await tick();
        expect(client.dispatched, ['climate.power.on']);

        client.seed('gear', 2); // one rule now false → AND fails
        client.push('b', 30); // reset trigger edge
        await tick();
        client.push('b', 10);
        await tick();
        expect(client.dispatched, [
          'climate.power.on',
        ], reason: 'AND false ⇒ no true-branch run');
      },
    );

    test('runaway governor disables a self-firing workflow', () async {
      engine.bindClient(client);
      // level edge + zero cooldown ⇒ fires every frame while true.
      engine.loadWorkflows([
        compile(doc(id: 'w', signal: 'b', op: '>', value: 0, edge: 'level')),
      ]);
      for (var i = 0; i < 20; i++) {
        client.push('b', 1);
        await tick();
      }
      expect(client.dispatched.length, kMaxRunsPerWorkflowPerWindow);
      expect(engine.isDisabled('w'), isTrue);
    });

    test('staleGuard fails closed when the trigger signal is stale', () async {
      engine.bindClient(client);
      engine.loadWorkflows([
        compile(
          doc(id: 'w', signal: 'b', op: '<', value: 20, staleGuardMs: 5000),
        ),
      ]);
      client.push('b', 10);
      client.seedAge('b', const Duration(seconds: 30)); // older than guard
      await tick();
      expect(client.dispatched, isEmpty);
    });

    test(
      'REGRESSION: re-binds to a new client on brand change, re-seeds without a '
      'phantom fire, and keeps firing (disposed-Ref guard)',
      () async {
        final clientA = client;
        engine.bindClient(clientA);
        engine.loadWorkflows([
          compile(doc(id: 'w', signal: 'b', op: '<', value: 20)),
        ]);

        clientA.push('b', 10); // fire on A
        await tick();
        expect(clientA.dispatched, ['climate.power.on']);

        // Brand re-resolve: a brand-new client instance, already in the
        // trigger-true state. Re-binding must NOT phantom-fire (it
        // re-seeds the edge), and must detach from A.
        final clientB = FakeCarClient();
        clientB.seed('b', 10); // already < 20
        engine.bindClient(clientB);
        await tick();
        expect(
          clientB.dispatched,
          isEmpty,
          reason: 're-seed must not phantom-fire',
        );
        expect(
          engine.isArmed,
          isTrue,
          reason: 'must subscribe to the new client',
        );

        // A is detached — frames on the old client do nothing.
        clientA.push('b', 30);
        clientA.push('b', 5);
        await tick();
        expect(clientA.dispatched.length, 1, reason: 'old client detached');

        // A real rising edge on B fires.
        clientB.push('b', 30); // reset
        await tick();
        clientB.push('b', 15); // false→true on B
        await tick();
        expect(clientB.dispatched, ['climate.power.on']);

        clientB.dispose();
      },
    );
  });
}
