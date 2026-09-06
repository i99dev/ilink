/// Tests for [FamilyExecutor] — the family-call lifecycle that
/// covers every native-capability op. Mirrors the admin-dispatcher
/// tests' SQLite-backed style so the real audit chain participates.
///
/// Local authorization is checked before every execution and replay.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/data/db/audit_chain_store.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';
import 'package:ilink/features/mini_apps/bridge/bridge_family_registry.dart';
import 'package:ilink/features/mini_apps/bridge/family_executor.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _certHash = 'cert-fam';
const _userId = 'u1';
const _vin = 'WDB-X';
const _appId = 'cluster-companion';

const _session = AdminSession(
  userId: _userId,
  deviceId: _vin,
  appId: _appId,
  certHash: _certHash,
);

class _RecordingHandler implements FamilyHandler {
  _RecordingHandler({
    Map<String, ParamRule>? paramSchema,
    this.behavior = _HandlerBehavior.success,
    this.requiresStepUp = false,
  }) : paramSchema = paramSchema ?? const {};
  @override
  final Map<String, ParamRule> paramSchema;
  @override
  final HandlerCadence cadence = HandlerCadence.standard;
  @override
  final bool requiresStepUp;
  final _HandlerBehavior behavior;
  int callCount = 0;
  final List<BridgeCall> calls = [];

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    callCount++;
    calls.add(call);
    switch (behavior) {
      case _HandlerBehavior.success:
        return {'ok': true, 'op': call.op};
      case _HandlerBehavior.bridgeError:
        throw const BridgeOpError(
          code: 'surface_denied',
          message: 'no display',
        );
      case _HandlerBehavior.crash:
        throw StateError('boom');
    }
  }
}

enum _HandlerBehavior { success, bridgeError, crash }

class _Family extends MiniAppFamily {
  _Family({
    required this.familyId,
    required this.handlers,
    this.permissionIds = const {'fake.read'},
  });
  @override
  final String familyId;
  @override
  final Map<String, FamilyHandler> handlers;
  @override
  final Set<String> permissionIds;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AuditChainStore audit;
  late BridgeFamilyRegistry registry;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    audit = AuditChainStore(db);
    registry = BridgeFamilyRegistry();
    addTearDown(db.close);
  });

  FamilyExecutor newExecutor({DateTime Function()? now}) {
    return FamilyExecutor(
      registry: registry,
      auditChain: audit,
      now: now,
      authorize: (_, _) async => true,
    );
  }

  test(
    'missing authorizer denies execution before handler side effects',
    () async {
      final handler = _RecordingHandler();
      registry.register(
        _Family(familyId: 'display', handlers: {'list': handler}),
      );
      final exec = FamilyExecutor(registry: registry, auditChain: audit);
      final result = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: {},
        session: _session,
      );
      expect((result as AdminExecError).code, 'permission_denied');
      expect(handler.callCount, 0);
    },
  );

  test(
    'revocation rejects a previously successful idempotency replay',
    () async {
      final handler = _RecordingHandler();
      registry.register(
        _Family(familyId: 'display', handlers: {'list': handler}),
      );
      var approved = true;
      final scopes = <String>[];
      final exec = FamilyExecutor(
        registry: registry,
        auditChain: audit,
        authorize: (session, scope) async {
          scopes.add(scope);
          return approved;
        },
      );
      final first = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: {},
        session: _session,
        idempotencyKey: 'retry',
      );
      expect(first, isA<AdminExecOk>());
      approved = false;
      final second = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: {},
        session: _session,
        idempotencyKey: 'retry',
      );
      expect((second as AdminExecError).code, 'permission_denied');
      expect(scopes, ['fake.read', 'fake.read']);
      expect(handler.callCount, 1);
    },
  );

  test(
    'sensitive handlers require host confirmation in addition to scope',
    () async {
      final handler = _RecordingHandler(requiresStepUp: true);
      registry.register(
        _Family(familyId: 'gesture', handlers: {'tap': handler}),
      );
      final exec = newExecutor();
      final denied = await exec.execute(
        familyId: 'gesture',
        op: 'tap',
        args: {},
        session: _session,
      );
      expect((denied as AdminExecError).code, 'permission_denied');
      expect(handler.callCount, 0);
      final allowed = await exec.execute(
        familyId: 'gesture',
        op: 'tap',
        args: {},
        session: _session,
        ownerConfirmed: true,
      );
      expect(allowed, isA<AdminExecOk>());
      expect(handler.callCount, 1);
    },
  );

  test(
    'a reused request key cannot execute another operation or bundle',
    () async {
      final handler = _RecordingHandler();
      registry.register(
        _Family(
          familyId: 'display',
          handlers: {'list': handler, 'other': handler},
        ),
      );
      final exec = newExecutor();
      await exec.execute(
        familyId: 'display',
        op: 'list',
        args: {},
        session: _session,
        idempotencyKey: 'same',
      );
      final other = await exec.execute(
        familyId: 'display',
        op: 'other',
        args: {},
        session: _session,
        idempotencyKey: 'same',
      );
      expect((other as AdminExecError).code, 'idempotency_conflict');
      const changed = AdminSession(
        userId: _userId,
        deviceId: _vin,
        appId: _appId,
        certHash: _certHash,
        bundleSha256: 'new-bundle',
      );
      final upgraded = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: {},
        session: changed,
        idempotencyKey: 'same',
      );
      expect((upgraded as AdminExecError).code, 'idempotency_conflict');
      expect(handler.callCount, 1);
    },
  );

  group('lookup', () {
    test('unknown family → unknown_template envelope', () async {
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'ghost',
        op: 'list',
        args: const {},
        session: _session,
      );
      expect(r, isA<AdminExecError>());
      final err = r as AdminExecError;
      expect(err.code, DispatchErrorCode.unknownTemplate);
      expect(err.message, contains('ghost'));
    });

    test('unknown op on a known family → unknown_template envelope', () async {
      registry.register(
        _Family(familyId: 'display', handlers: {'list': _RecordingHandler()}),
      );
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'display',
        op: 'subscribe',
        args: const {},
        session: _session,
      );
      expect(r, isA<AdminExecError>());
      expect((r as AdminExecError).message, contains('display.subscribe'));
    });
  });

  group('param validation', () {
    test('unknown slot → param_validation_failed', () async {
      registry.register(
        _Family(familyId: 'display', handlers: {'list': _RecordingHandler()}),
      );
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: const {'unexpected': 1},
        session: _session,
      );
      expect(
        (r as AdminExecError).code,
        DispatchErrorCode.paramValidationFailed,
      );
    });

    test('regex rule rejects bad input', () async {
      registry.register(
        _Family(
          familyId: 'pkg',
          handlers: {
            'launch': _RecordingHandler(
              paramSchema: {
                'packageName': RegexParamRule(pattern: r'^[a-z][a-z0-9_.]*$'),
              },
            ),
          },
        ),
      );
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'pkg',
        op: 'launch',
        args: const {'packageName': '../etc/passwd'},
        session: _session,
      );
      expect(
        (r as AdminExecError).code,
        DispatchErrorCode.paramValidationFailed,
      );
    });

    test('int default fills in when slot missing', () async {
      final h = _RecordingHandler(
        paramSchema: {
          'lines': const IntParamRule(min: 1, max: 1000, defaultValue: 50),
        },
      );
      registry.register(_Family(familyId: 'diag', handlers: {'tail': h}));
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'diag',
        op: 'tail',
        args: const {},
        session: _session,
      );
      expect(r, isA<AdminExecOk>());
      expect(h.calls.single.params['lines'], 50);
    });
  });

  group('handler errors', () {
    test('BridgeOpError surfaces with its code + message', () async {
      registry.register(
        _Family(
          familyId: 'surface',
          permissionIds: const {'surface.read'},
          handlers: {
            'list': _RecordingHandler(behavior: _HandlerBehavior.bridgeError),
          },
        ),
      );
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'surface',
        op: 'list',
        args: const {},
        session: _session,
      );
      final err = r as AdminExecError;
      expect(err.code, 'surface_denied');
      expect(err.message, 'no display');
    });

    test('generic exception → internal_error', () async {
      registry.register(
        _Family(
          familyId: 'surface',
          permissionIds: const {'surface.read'},
          handlers: {
            'list': _RecordingHandler(behavior: _HandlerBehavior.crash),
          },
        ),
      );
      final exec = newExecutor();
      final r = await exec.execute(
        familyId: 'surface',
        op: 'list',
        args: const {},
        session: _session,
      );
      expect((r as AdminExecError).code, DispatchErrorCode.internalError);
    });
  });

  group('audit + idempotency', () {
    test('successful call writes one audit row', () async {
      registry.register(
        _Family(
          familyId: 'display',
          permissionIds: const {'display.read'},
          handlers: {'list': _RecordingHandler()},
        ),
      );
      final exec = newExecutor();
      await exec.execute(
        familyId: 'display',
        op: 'list',
        args: const {},
        session: _session,
      );
      final rows = await audit.sliceForUpload(appId: _appId, limit: 10);
      expect(rows, hasLength(1));
      expect(rows.first.op, 'display.list');
      expect(rows.first.success, isTrue);
      expect(rows.first.payload['cadence'], 'standard');
    });

    test('idempotency key replays the prior envelope', () async {
      final h = _RecordingHandler();
      registry.register(
        _Family(
          familyId: 'display',
          permissionIds: const {'display.read'},
          handlers: {'list': h},
        ),
      );
      final exec = newExecutor();
      final r1 = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: const {},
        session: _session,
        idempotencyKey: 'k-1',
      );
      final r2 = await exec.execute(
        familyId: 'display',
        op: 'list',
        args: const {},
        session: _session,
        idempotencyKey: 'k-1',
      );
      expect(r1, isA<AdminExecOk>());
      expect(r2, isA<AdminExecOk>());
      expect(h.callCount, 1, reason: 'second call replays from audit row');
    });
  });

  group('capabilities handshake', () {
    test('familyIdsForCapabilities mirrors registry', () {
      registry.register(_Family(familyId: 'a', handlers: {}));
      registry.register(_Family(familyId: 'b', handlers: {}));
      final exec = newExecutor();
      expect(exec.familyIdsForCapabilities().toList(), ['a', 'b']);
    });
  });
}
