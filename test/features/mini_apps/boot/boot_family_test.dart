/// Tests for [BootFamily] + [BootStore] against an in-memory SQLite.
///
/// Verifies set/list/unset round-trip semantics, the
/// (user, deviceId, app, packageName) primary-key dedupe behaviour, and
/// the per-mini-app isolation that prevents cross-app boot snooping.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/data/db/admin_db.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';
import 'package:ilink/features/mini_apps/lifecycle/boot_family.dart';
import 'package:ilink/features/mini_apps/lifecycle/boot_store.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _session = AdminSession(
  userId: 'u1',
  deviceId: 'VIN1',
  appId: 'auto-launch',
  certHash: 'cert',
);

BridgeCall _call(String op, [Map<String, Object?> params = const {}]) =>
    BridgeCall(familyId: 'boot', op: op, params: params, session: _session);

void main() {
  setUpAll(sqfliteFfiInit);

  late BootStore store;
  late BootFamily family;

  setUp(() async {
    final db = await openAdminDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = BootStore(db);
    family = BootFamily.withStore(store);
    addTearDown(db.close);
  });

  group('BootFamily metadata', () {
    test('familyId / permissions / privileged posture', () {
      expect(family.familyId, 'boot');
      expect(family.permissionIds, {'boot.write'});
      expect(family.secondaryAllowed, isFalse);
    });
  });

  group('BootFamily set + list + unset', () {
    test('set persists a row, list returns it', () async {
      final r = await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps', 'displayId': 4}),
      );
      expect(r['packageName'], 'com.byd.maps');
      expect(r['displayId'], 4);
      expect(r['setAtMs'], isA<int>());

      final list = await family.handlers['list']!.execute(_call('list'));
      final entries = list['entries']! as List;
      expect(entries, hasLength(1));
      expect((entries.first as Map)['packageName'], 'com.byd.maps');
    });

    test('default displayId is -1 (host default display)', () async {
      final r = await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps'}),
      );
      expect(r['displayId'], -1);
    });

    test('set is idempotent on (user, deviceId, app, packageName)', () async {
      await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps', 'displayId': 4}),
      );
      // Second set with the same packageName replaces (not duplicates).
      await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps', 'displayId': 5}),
      );
      final list = await family.handlers['list']!.execute(_call('list'));
      final entries = list['entries']! as List;
      expect(entries, hasLength(1));
      expect((entries.first as Map)['displayId'], 5);
    });

    test('unset removes only the matching row', () async {
      await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps'}),
      );
      await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.music'}),
      );

      final r = await family.handlers['unset']!.execute(
        _call('unset', {'packageName': 'com.byd.maps'}),
      );
      expect(r['removed'], 1);

      final list = await family.handlers['list']!.execute(_call('list'));
      final entries = list['entries']! as List;
      expect(entries, hasLength(1));
      expect((entries.first as Map)['packageName'], 'com.byd.music');
    });

    test('unset of missing row returns 0 (idempotent)', () async {
      final r = await family.handlers['unset']!.execute(
        _call('unset', {'packageName': 'com.never.installed'}),
      );
      expect(r['removed'], 0);
    });

    test('list never reveals other mini-apps\' boot rows', () async {
      // App A declares its boot package.
      await family.handlers['set']!.execute(
        _call('set', {'packageName': 'com.byd.maps'}),
      );
      // App B comes in under the same (user, deviceId) but a different
      // appId — its list call must not see A's row.
      const otherSession = AdminSession(
        userId: 'u1',
        deviceId: 'VIN1',
        appId: 'other-app',
        certHash: 'cert',
      );
      final list = await family.handlers['list']!.execute(
        const BridgeCall(
          familyId: 'boot',
          op: 'list',
          params: {},
          session: otherSession,
        ),
      );
      final entries = list['entries']! as List;
      expect(entries, isEmpty);
    });
  });

  group('BootFamily validation', () {
    test('set rejects empty packageName', () async {
      await expectLater(
        () =>
            family.handlers['set']!.execute(_call('set', {'packageName': ''})),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'boot_invalid'),
        ),
      );
    });

    test('set rejects malformed packageName', () async {
      await expectLater(
        () => family.handlers['set']!.execute(
          _call('set', {'packageName': 'no-dot'}),
        ),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'boot_invalid'),
        ),
      );
    });

    test('unset rejects empty packageName', () async {
      await expectLater(
        () => family.handlers['unset']!.execute(
          _call('unset', {'packageName': ''}),
        ),
        throwsA(
          isA<BridgeOpError>().having((e) => e.code, 'code', 'boot_invalid'),
        ),
      );
    });
  });

  group('BootStore.listAllFor (cross-app boot enumeration)', () {
    test(
      'returns every row under (user, deviceId) for the launcher hook',
      () async {
        // App A declares two packages.
        await store.set(
          userId: 'u1',
          deviceId: 'VIN1',
          appId: 'app-a',
          packageName: 'com.byd.maps',
          displayId: 4,
        );
        await store.set(
          userId: 'u1',
          deviceId: 'VIN1',
          appId: 'app-a',
          packageName: 'com.byd.music',
          displayId: -1,
        );
        // App B declares one.
        await store.set(
          userId: 'u1',
          deviceId: 'VIN1',
          appId: 'app-b',
          packageName: 'com.byd.weather',
          displayId: 5,
        );
        // A different (user, deviceId) — should NOT show up.
        await store.set(
          userId: 'u2',
          deviceId: 'VIN1',
          appId: 'app-a',
          packageName: 'com.intruder',
          displayId: -1,
        );

        final rows = await store.listAllFor(userId: 'u1', deviceId: 'VIN1');
        expect(rows.map((r) => r.packageName).toSet(), {
          'com.byd.maps',
          'com.byd.music',
          'com.byd.weather',
        });
      },
    );
  });

  group('BootStore.clearForApp (uninstall hook)', () {
    test('wipes every row for one mini-app, leaves others alone', () async {
      await store.set(
        userId: 'u1',
        deviceId: 'VIN1',
        appId: 'app-a',
        packageName: 'com.byd.maps',
        displayId: 4,
      );
      await store.set(
        userId: 'u1',
        deviceId: 'VIN1',
        appId: 'app-b',
        packageName: 'com.byd.music',
        displayId: -1,
      );

      final removed = await store.clearForApp(appId: 'app-a');
      expect(removed, 1);

      final remaining = await store.listAllFor(userId: 'u1', deviceId: 'VIN1');
      expect(remaining, hasLength(1));
      expect(remaining.single.appId, 'app-b');
    });
  });
}
