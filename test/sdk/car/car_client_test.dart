/// CarClient unit tests — exercise the SDK's public surface against a
/// scriptable fake transport. Covers value/watch/freshness, derive
/// recompute (single + multi-source), connection state, and dispatch
/// routing.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/sdk/brands/byd/byd_client.dart';
import 'package:ilink/sdk/car/client.dart';

import 'fake_car_transport.dart';

BydClient _newClient([FakeCarTransport? t]) =>
    BydClient.forTest(t ?? FakeCarTransport());

void main() {
  group('CarClient — read surface', () {
    test('value() returns null before any push', () {
      final client = _newClient();
      expect(
        client.value('Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE'),
        isNull,
      );
    });

    test('liveFeaturesSync returns empty before seed completes', () {
      final client = _newClient();
      expect(client.liveFeaturesSync(), isEmpty);
    });

    test('freshness returns null for never-seen names', () {
      final client = _newClient();
      expect(
        client.freshness('Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE'),
        isNull,
      );
    });

    test('handlePushForTest stamps freshness', () async {
      final client = _newClient();
      client.handlePushForTest('Statistic.STATISTIC_SPEED_SIG_VDIS', 42);
      expect(client.value('Statistic.STATISTIC_SPEED_SIG_VDIS'), 42);
      final age = client.freshness('Statistic.STATISTIC_SPEED_SIG_VDIS');
      expect(age, isNotNull);
      expect(age!.inSeconds, lessThan(2));
    });
  });

  group('CarClient — derive', () {
    test('derive computes initial value on register', () {
      final client = _newClient();
      client.setForTest('a', 5);
      client.setForTest('b', 7);

      final handle = client.derive(
        name: 'derived.sum',
        sources: const ['a', 'b'],
        compute: (vals) => (vals['a'] ?? 0) + (vals['b'] ?? 0),
      );

      expect(client.value('derived.sum'), 12);
      handle.dispose();
    });

    test('derive recomputes when a source changes', () {
      final client = _newClient();
      client.setForTest('a', 1);
      client.setForTest('b', 2);

      client.derive(
        name: 'derived.sum',
        sources: const ['a', 'b'],
        compute: (vals) => (vals['a'] ?? 0) + (vals['b'] ?? 0),
      );
      expect(client.value('derived.sum'), 3);

      client.handlePushForTest('a', 10);
      expect(client.value('derived.sum'), 12);

      client.handlePushForTest('b', 20);
      expect(client.value('derived.sum'), 30);
    });

    test('derive returning null clears the cached entry', () {
      final client = _newClient();

      client.derive(
        name: 'derived.guarded',
        sources: const ['x'],
        compute: (vals) => vals['x'] == null ? null : vals['x']! * 2,
      );
      expect(client.value('derived.guarded'), isNull);

      client.handlePushForTest('x', 5);
      expect(client.value('derived.guarded'), 10);
    });

    test('dispose() unregisters the derive', () {
      final client = _newClient();
      client.setForTest('a', 1);

      final handle = client.derive(
        name: 'derived.echo',
        sources: const ['a'],
        compute: (vals) => vals['a'],
      );
      expect(client.value('derived.echo'), 1);

      handle.dispose();
      expect(client.value('derived.echo'), isNull);
      client.handlePushForTest('a', 99);
      expect(
        client.value('derived.echo'),
        isNull,
        reason: 'a push after dispose must NOT resurrect the derive',
      );
    });

    test('source index fires only the affected derive', () {
      final client = _newClient();
      var aPlusBComputes = 0;
      var cAlone = 0;

      client.derive(
        name: 'derived.aplusb',
        sources: const ['a', 'b'],
        compute: (vals) {
          aPlusBComputes++;
          return (vals['a'] ?? 0) + (vals['b'] ?? 0);
        },
      );
      client.derive(
        name: 'derived.c',
        sources: const ['c'],
        compute: (vals) {
          cAlone++;
          return vals['c'];
        },
      );

      // Reset counters after registration's initial compute.
      aPlusBComputes = 0;
      cAlone = 0;

      client.handlePushForTest('c', 42);
      expect(cAlone, 1);
      expect(
        aPlusBComputes,
        0,
        reason: 'pushing c must NOT recompute the a+b derive',
      );
    });
  });

  group('CarClient — connection state', () {
    test('starts connected', () {
      final client = _newClient();
      expect(client.currentConnectionState, DaemonState.connected);
    });

    test(
      'connectionState() emits current value immediately on listen',
      () async {
        final client = _newClient();
        final first = await client.connectionState().first;
        expect(first, DaemonState.connected);
      },
    );
  });

  group('CarClient — dispatch routing', () {
    test('invoke() passes through to runAction', () async {
      final t = FakeCarTransport()
        ..runActionResponse = const {'ok': true, 'code': 0};
      final client = BydClient.forTest(t);

      await client.invoke('door.lock', const {'foo': 'bar'});
      final hit = t.calls.firstWhere((c) => c.method == 'runAction');
      expect(hit.args['id'], 'door.lock');
      expect(hit.args['args'], const {'foo': 'bar'});
    });

    test('dispatch() in test mode falls back to runAction', () async {
      final t = FakeCarTransport()
        ..runActionResponse = const {'ok': true, 'code': 0};
      final client = BydClient.forTest(t);

      await client.dispatch('trunk.open', args: const {});
      expect(t.calls.where((c) => c.method == 'runAction').length, 1);
    });
  });
}
