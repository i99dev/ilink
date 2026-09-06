/// Tests for [FamilyEventPusher] + the executor's pusher passthrough.
/// Pure-Dart; no platform involvement.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/audit_chain_store.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';
import 'package:ilink/features/mini_apps/bridge/bridge_family_registry.dart';
import 'package:ilink/features/mini_apps/bridge/family_event_pusher.dart';
import 'package:ilink/features/mini_apps/bridge/family_executor.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _session = AdminSession(
  userId: 'u',
  deviceId: 'V',
  appId: 'cluster-hello-world',
  certHash: 'c',
);

/// Handler that captures whatever pusher its [BridgeCall] carries —
/// then we can assert the executor's passthrough is wired correctly.
class _CapturingHandler implements FamilyHandler {
  FamilyEventPusher? capturedPusher;
  @override
  Map<String, ParamRule> get paramSchema => const {};
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;
  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    capturedPusher = call.eventPusher;
    return {'ok': true};
  }
}

class _Family extends MiniAppFamily {
  _Family(this.handlers);
  @override
  String get familyId => 'sub';
  @override
  Set<String> get permissionIds => const {'sub.read'};
  @override
  final Map<String, FamilyHandler> handlers;
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('FakeFamilyEventPusher', () {
    test('records every pushEvent call', () {
      final p = FakeFamilyEventPusher();
      p.pushEvent('display', {'type': 'added', 'displayId': 4});
      p.pushEvent('display', {'type': 'removed', 'displayId': 5});
      expect(p.events, hasLength(2));
      expect(p.events[0].channel, 'display');
      expect(p.events[0].payload['displayId'], 4);
      expect(p.events[1].payload['type'], 'removed');
    });

    test('clear() empties the buffer', () {
      final p = FakeFamilyEventPusher();
      p.pushEvent('x', {});
      expect(p.events, hasLength(1));
      p.clear();
      expect(p.events, isEmpty);
    });
  });

  group('NoopFamilyEventPusher', () {
    test('swallows pushes without throwing', () {
      const p = NoopFamilyEventPusher();
      // Just shouldn't throw. No state to inspect.
      p.pushEvent('display', {'type': 'snapshot'});
    });
  });

  group('FamilyExecutor passthrough', () {
    late FamilyExecutor exec;
    late _CapturingHandler handler;
    late BridgeFamilyRegistry registry;

    setUp(() async {
      final db = await openAdminDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      registry = BridgeFamilyRegistry();
      handler = _CapturingHandler();
      registry.register(_Family({'read': handler}));
      exec = FamilyExecutor(
        registry: registry,
        auditChain: AuditChainStore(db),
        authorize: (_, _) async => true,
      );
      addTearDown(db.close);
    });

    test(
      'default execute() passes a NoopFamilyEventPusher to the handler',
      () async {
        await exec.execute(
          familyId: 'sub',
          op: 'read',
          args: const {},
          session: _session,
        );
        expect(handler.capturedPusher, isA<NoopFamilyEventPusher>());
      },
    );

    test('caller-provided pusher is passed through verbatim', () async {
      final myPusher = FakeFamilyEventPusher();
      await exec.execute(
        familyId: 'sub',
        op: 'read',
        args: const {},
        session: _session,
        eventPusher: myPusher,
      );
      expect(handler.capturedPusher, same(myPusher));
    });
  });
}
