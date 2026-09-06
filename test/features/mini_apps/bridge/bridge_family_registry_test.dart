/// Architecture tests for [BridgeFamilyRegistry] + [MiniAppFamily].
///
/// These prove the centralisation contract: adding a family is one
/// [register] call; nothing else in the bridge layer needs to
/// change. The registry is insertion-ordered, dedup-checked, and
/// surfaces the list `_handleCapabilities` needs to publish.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_op.dart';
import 'package:ilink/features/mini_apps/bridge/bridge_family_registry.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';

class _FakeHandler implements FamilyHandler {
  _FakeHandler({this.cadence = HandlerCadence.standard});
  @override
  final HandlerCadence cadence;
  @override
  Map<String, ParamRule> get paramSchema => const {};
  @override
  bool get requiresStepUp => false;
  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async => {'ok': true};
}

class _FakeFamily extends MiniAppFamily {
  _FakeFamily({
    required this.familyId,
    this.permissionIds = const {'fake.read'},
  });

  @override
  final String familyId;
  @override
  final Set<String> permissionIds;
  @override
  Map<String, FamilyHandler> get handlers => const {};
}

void main() {
  group('BridgeFamilyRegistry', () {
    test('register + lookup round-trips', () {
      final r = BridgeFamilyRegistry();
      final fam = _FakeFamily(familyId: 'display');
      r.register(fam);
      expect(r.lookup('display'), same(fam));
      expect(r.lookup('missing'), isNull);
      expect(r.length, 1);
    });

    test('preserves insertion order', () {
      final r = BridgeFamilyRegistry();
      r.register(_FakeFamily(familyId: 'display'));
      r.register(_FakeFamily(familyId: 'surface'));
      r.register(_FakeFamily(familyId: 'cursor'));
      expect(r.familyIds.toList(), ['display', 'surface', 'cursor']);
    });

    test('throws DuplicateFamilyError on second register', () {
      final r = BridgeFamilyRegistry();
      r.register(_FakeFamily(familyId: 'display'));
      expect(
        () => r.register(_FakeFamily(familyId: 'display')),
        throwsA(isA<DuplicateFamilyError>()),
      );
    });

    test('clearForTests empties the registry', () {
      final r = BridgeFamilyRegistry();
      r.register(_FakeFamily(familyId: 'display'));
      expect(r.length, 1);
      r.clearForTests();
      expect(r.length, 0);
      expect(r.lookup('display'), isNull);
    });

    test('A5 contract: adding family N+1 takes one register call', () {
      // Empirical proof: the registry has no special-case branching on
      // family count, so registering the Nth family is the same cost
      // as the first. This test guards against accidental bookkeeping
      // (e.g. a hand-written switch) sneaking back in.
      final r = BridgeFamilyRegistry();
      for (var i = 0; i < 50; i++) {
        r.register(_FakeFamily(familyId: 'fam_$i'));
      }
      expect(r.length, 50);
      expect(r.lookup('fam_0')?.familyId, 'fam_0');
      expect(r.lookup('fam_49')?.familyId, 'fam_49');
    });
  });

  group('MiniAppFamily.permissionIdFor default', () {
    test('returns the single permission when family has exactly one', () {
      final fam = _FakeFamily(
        familyId: 'display',
        permissionIds: const {'display.read'},
      );
      expect(fam.permissionIdFor('list'), 'display.read');
      expect(fam.permissionIdFor('subscribe'), 'display.read');
    });

    test('throws when called on a multi-perm family without override', () {
      final fam = _FakeFamily(
        familyId: 'pkg',
        permissionIds: const {'pkg.read', 'pkg.launch'},
      );
      expect(() => fam.permissionIdFor('list'), throwsStateError);
    });
  });

  group('FamilyHandler defaults', () {
    test('handler exposes its cadence', () {
      final h = _FakeHandler(cadence: HandlerCadence.hot);
      expect(h.cadence, HandlerCadence.hot);
    });
  });

  group('BridgeOpError', () {
    test('toString includes code', () {
      const e = BridgeOpError(code: 'surface_denied', message: 'no display');
      expect(e.toString(), contains('surface_denied'));
      expect(e.toString(), contains('no display'));
    });
  });
}
