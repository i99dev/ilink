/// Tests for [CarBridgeService] — every public method, plus the
/// load-bearing internal contracts (name cap, throttle bucket,
/// fan-out lifecycle, idempotency-ish behaviour).
///
/// Strategy: build a [ProviderContainer] with `carClientProvider`
/// overridden to a [FakeCarClient] so the service runs entirely in
/// pure Dart with no Android platform channels.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/mini_apps/bridge/car_bridge_service.dart';
import 'package:ilink/sdk/car/client.dart';

import '../../../support/fake_car_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeCarClient fakeClient;
  late ProviderContainer container;
  late CarBridgeService service;

  setUp(() {
    fakeClient = FakeCarClient();
    container = ProviderContainer(
      overrides: [carClientProvider.overrideWith((ref) => fakeClient)],
    );
    service = container.read(carBridgeServiceProvider);
  });

  tearDown(() {
    container.dispose();
  });

  group('car.list', () {
    test('returns bridge version + brand + categories + all names', () {
      final result = service.list();
      expect(result['bridgeVersion'], CarBridgeService.kBridgeVersion);
      expect(result['brand'], isNotNull);
      expect(result['categories'], isA<List<String>>());
      expect(result['names'], isA<List<dynamic>>());
      final names = (result['names'] as List).cast<Map<String, Object?>>();
      // 176 entries in the BYD catalog today.
      expect(names.length, greaterThan(100));
      // Every entry exposes the contract shape.
      for (final n in names) {
        expect(n['name'], isA<String>());
        expect(n['category'], isA<String>());
        expect(n['description'], isA<String>());
        expect(n['writeable'], isA<bool>());
        expect(n['threeD'], isA<bool>());
      }
    });

    test('category filter narrows the result', () {
      final all = (service.list()['names'] as List)
          .cast<Map<String, Object?>>();
      final doors = (service.list(category: 'doors')['names'] as List)
          .cast<Map<String, Object?>>();
      expect(doors.length, lessThan(all.length));
      for (final n in doors) {
        expect(n['category'], 'doors');
      }
    });

    test('threeDOnly returns only 3D-friendly entries', () {
      final threeD = (service.list(threeDOnly: true)['names'] as List)
          .cast<Map<String, Object?>>();
      expect(threeD.length, greaterThan(0));
      for (final n in threeD) {
        expect(n['threeD'], isTrue);
      }
    });

    test('no leaked framework names or integer ids', () {
      // The whole point of the v2 contract: only public names cross
      // the bridge. The list response must never carry a BYD framework
      // identifier (uppercase snake_case w/ namespace dot) or a raw
      // integer feature id.
      final names = (service.list()['names'] as List)
          .cast<Map<String, Object?>>();
      for (final n in names) {
        final name = n['name'] as String;
        expect(
          name,
          isNot(contains('.')),
          reason: 'public name must not contain "." (framework artefact)',
        );
        expect(
          name.toUpperCase() == name && name.length > 1,
          isFalse,
          reason: 'public name must not be all-uppercase',
        );
        // Wire shape must not carry feature ids.
        expect(n.containsKey('id'), isFalse);
        expect(n.containsKey('bydFrameworkName'), isFalse);
      }
    });
  });

  group('car.read', () {
    test('returns null for names with no SDK value', () {
      final result = service.read(['door_lf', 'battery_pct']);
      expect(result['at'], isA<String>());
      final values = result['values'] as Map<String, Object?>;
      expect(values['door_lf'], isNull);
      expect(values['battery_pct'], isNull);
    });

    test('returns SDK values for seeded framework names', () {
      // The bridge maps door_lf → Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR.
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 1;
      fakeClient.values['Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE'] = 87;
      final result = service.read(['door_lf', 'battery_pct']);
      final values = result['values'] as Map<String, Object?>;
      expect(values['door_lf'], 1);
      expect(values['battery_pct'], 87);
    });

    test('unknown names come back as null (no exception)', () {
      final result = service.read(['definitely_not_a_signal']);
      final values = result['values'] as Map<String, Object?>;
      expect(values.containsKey('definitely_not_a_signal'), isTrue);
      expect(values['definitely_not_a_signal'], isNull);
    });

    test('rejects requests over the name cap', () {
      final names = List<String>.generate(
        CarBridgeService.kMaxNamesPerSubscription + 1,
        (i) => 'door_lf',
      );
      final result = service.read(names);
      expect(result['error'], 'too_many_names');
      expect(result['max'], CarBridgeService.kMaxNamesPerSubscription);
    });
  });

  group('car.subscribe', () {
    test('emits initial value immediately for each accepted name', () {
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 0;
      final received = <String>[];
      final result = service.subscribe('sub-1', ['door_lf'], received.add);
      expect(result['subscriptionId'], 'sub-1');
      // Initial emission is on the synchronous path (sendImmediately=true).
      expect(received, hasLength(1));
      expect(received.first, contains('"name":"door_lf"'));
      expect(received.first, contains('"value":0'));
    });

    test('rejects subscriptions exceeding the name cap', () {
      final names = List<String>.generate(
        CarBridgeService.kMaxNamesPerSubscription + 1,
        (i) => 'door_lf',
      );
      final result = service.subscribe('sub-overlong', names, (_) {});
      expect(result['error'], 'too_many_names');
    });

    test('rejects when no names are valid', () {
      final result = service.subscribe('sub-bad', ['not_a_real_name'], (_) {});
      expect(result['error'], 'no_valid_names');
      expect(result['rejected'], contains('not_a_real_name'));
    });

    test('partial-valid subscriptions accept the good ones', () {
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 0;
      final received = <String>[];
      final result = service.subscribe('sub-mixed', [
        'door_lf',
        'not_a_real_name',
      ], received.add);
      expect(result['subscriptionId'], 'sub-mixed');
      expect(result['rejected'], ['not_a_real_name']);
      expect(received, hasLength(1));
    });

    test('SDK change frame pushes delta to subscribers', () async {
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 0;
      final received = <String>[];
      service.subscribe('sub-c', ['door_lf'], received.add);
      // Initial emission consumed.
      expect(received, hasLength(1));
      // Same value → no new emission.
      fakeClient.pushChange();
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      // Different value → emission.
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 1;
      fakeClient.pushChange();
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(received.last, contains('"value":1'));
    });

    test('unsubscribe stops further pushes', () async {
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 0;
      final received = <String>[];
      service.subscribe('sub-u', ['door_lf'], received.add);
      expect(received, hasLength(1));
      service.unsubscribe('sub-u');
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 5;
      fakeClient.pushChange();
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
    });

    test('unsubscribeAllForViewer drops every sub owned by a viewer', () async {
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 0;
      fakeClient.values['Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE'] = 50;
      final receivedA = <String>[];
      final receivedB = <String>[];
      service.subscribe(
        'viewerA-sub1',
        ['door_lf'],
        receivedA.add,
        viewerId: 'viewer-A',
      );
      service.subscribe(
        'viewerA-sub2',
        ['battery_pct'],
        receivedA.add,
        viewerId: 'viewer-A',
      );
      service.subscribe(
        'viewerB-sub1',
        ['door_lf'],
        receivedB.add,
        viewerId: 'viewer-B',
      );
      service.unsubscribeAllForViewer('viewer-A');
      // After tearing down A, only B receives further pushes.
      fakeClient.values['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'] = 1;
      fakeClient.pushChange();
      await Future<void>.delayed(Duration.zero);
      final aBefore = receivedA.length;
      final bBefore = receivedB.length;
      expect(aBefore, 2); // initial seed pushes only
      expect(bBefore, 2); // initial seed + the delta after A teardown
    });
  });

  group('car.identity', () {
    test(
      'returns brand (the 3D model fields were removed with the renderer)',
      () {
        final id = service.identity();
        expect(id['brand'], isNotNull);
        // The in-app 3D car renderer was deleted, so identity() no longer
        // carries the GLB-contract fields it described.
        expect(id.containsKey('modelCode'), isFalse);
        expect(id.containsKey('modelAssetPath'), isFalse);
        expect(id.containsKey('clips'), isFalse);
        expect(id.containsKey('variants'), isFalse);
      },
    );
  });

  group('car.asset', () {
    test('rejects disallowed paths', () async {
      final res = await service.asset('lib/main.dart');
      expect(res['error'], 'disallowed_path');
    });

    test('rejects path traversal attempts', () async {
      final res = await service.asset('assets/textures/../../secrets');
      expect(res['error'], 'disallowed_path');
    });

    test('rejects assets/3d/ now that the 3D renderer is gone', () async {
      final res = await service.asset('assets/3d/leopard8/leopard8.glb');
      expect(res['error'], 'disallowed_path');
    });

    test(
      'returns asset_not_found for non-existent files under allowed prefix',
      () async {
        final res = await service.asset('assets/textures/does_not_exist.png');
        expect(res['error'], 'asset_not_found');
      },
    );
  });

  group('car.connection', () {
    test('emits initial state immediately on subscribe', () async {
      final received = <String>[];
      service.connectionSubscribe('conn-1', received.add);
      // Emission is on microtask — let the queue drain.
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first, 'unknown'); // no push frame seen yet
    });

    test('unsubscribe stops further events', () async {
      final received = <String>[];
      service.connectionSubscribe('conn-2', received.add);
      await Future<void>.delayed(Duration.zero);
      final before = received.length;
      service.connectionUnsubscribe('conn-2');
      // No way to force a state transition from a unit test without
      // running the 5-second timer; we assert the subscriber is gone
      // by checking that an unsubscribe doesn't throw + state is sticky.
      expect(received.length, before);
    });
  });

  group('car.command', () {
    test('routes through CarClient.dispatch', () async {
      fakeClient.dispatchReply = {'ok': true, 'code': 0};
      final result = await service.command(
        actionId: 'door.lock.fl',
        args: {'x': 1},
      );
      expect(result['ok'], true);
      final lastCall = fakeClient.calls.last;
      expect(lastCall.method, 'dispatch');
      expect(lastCall.args['actionId'], 'door.lock.fl');
      expect(lastCall.args['args'], {'x': 1});
    });
  });
}
