/// Tests for [DisplayFamily]. Pure-Dart — fakes the native bridge,
/// no platform involvement.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/bridge/family_event_pusher.dart';
import 'package:ilink/features/mini_apps/bridge/mini_app_family.dart';
import 'package:ilink/features/mini_apps/runtime/display_family.dart';
import 'package:ilink/features/mini_apps/runtime/display_native_bridge.dart';
import 'package:ilink/features/mini_apps/runtime/display_snapshot.dart';
import 'package:ilink/features/admin_mini_apps/domain/admin_dispatcher.dart';

class _FakeBridge implements DisplayNativeBridge {
  _FakeBridge(this._snap);
  final List<DisplaySnapshot> _snap;
  @override
  Future<List<DisplaySnapshot>> list() async => _snap;
  @override
  Stream<DisplayEvent> events() => const Stream.empty();
  @override
  Future<DensityResult> setDensity({
    required int displayId,
    required int dpi,
  }) async => DensityResult(ok: true, displayId: displayId);
  @override
  Future<DensityResult> resetDensity({required int displayId}) async =>
      DensityResult(ok: true, displayId: displayId);
  @override
  Future<VehicleCapabilityResult> capabilityBits({String? fingerprint}) async =>
      const VehicleCapabilityResult(bits: 0, capabilities: []);
}

/// Bridge backed by a [StreamController] so tests can pump events
/// at will.
class _ControllableBridge implements DisplayNativeBridge {
  final StreamController<DisplayEvent> _controller =
      StreamController<DisplayEvent>.broadcast();

  @override
  Future<List<DisplaySnapshot>> list() async => const [];

  @override
  Stream<DisplayEvent> events() => _controller.stream;

  @override
  Future<DensityResult> setDensity({
    required int displayId,
    required int dpi,
  }) async => DensityResult(ok: true, displayId: displayId);
  @override
  Future<DensityResult> resetDensity({required int displayId}) async =>
      DensityResult(ok: true, displayId: displayId);
  @override
  Future<VehicleCapabilityResult> capabilityBits({String? fingerprint}) async =>
      const VehicleCapabilityResult(bits: 0, capabilities: []);

  void emit(DisplayEvent e) => _controller.add(e);
  Future<void> close() => _controller.close();
}

const _session = AdminSession(
  userId: 'u',
  deviceId: 'V',
  appId: 'a',
  certHash: 'c',
);

void main() {
  group('DisplayFamily', () {
    test('familyId / permissionIds / secondaryAllowed', () {
      final fam = DisplayFamily(bridge: _FakeBridge(const []));
      expect(fam.familyId, 'display');
      expect(fam.permissionIds, {'display.read'});
      expect(
        fam.secondaryAllowed,
        isTrue,
        reason: 'display enumeration is safe to expose on a secondary surface',
      );
    });

    test('list handler returns the bridge snapshot', () async {
      const ivi = DisplaySnapshot(
        id: 0,
        name: 'IVI',
        width: 1920,
        height: 1200,
        densityDpi: 240,
        isDefault: true,
        isPresentation: false,
        isCluster: false,
      );
      const cluster = DisplaySnapshot(
        id: 4,
        name: 'shared_fission_bg_XDJAScreenProjection_0',
        width: 1920,
        height: 720,
        densityDpi: 320,
        isDefault: false,
        isPresentation: true,
        isCluster: true,
      );
      final fam = DisplayFamily(bridge: _FakeBridge(const [ivi, cluster]));
      final h = fam.handlers['list']!;
      expect(h.cadence, HandlerCadence.standard);
      expect(h.requiresStepUp, isFalse);
      expect(h.paramSchema, isEmpty);

      final out = await h.execute(
        const BridgeCall(
          familyId: 'display',
          op: 'list',
          params: {},
          session: _session,
        ),
      );
      final displays = out['displays'] as List;
      expect(displays, hasLength(2));
      expect((displays[0] as Map)['id'], 0);
      expect((displays[1] as Map)['id'], 4);
      expect((displays[1] as Map)['isCluster'], isTrue);
      expect(
        (displays[1] as Map)['name'],
        'shared_fission_bg_XDJAScreenProjection_0',
      );
    });
  });

  group('DisplaySnapshot round-trip', () {
    test('toJson + fromMap is byte-equivalent', () {
      const original = DisplaySnapshot(
        id: 4,
        name: 'fission_bg_XDJAScreenProjection',
        width: 1920,
        height: 720,
        densityDpi: 320,
        isDefault: false,
        isPresentation: true,
        isCluster: true,
      );
      final round = DisplaySnapshot.fromMap(original.toJson());
      expect(round.id, original.id);
      expect(round.name, original.name);
      expect(round.isCluster, original.isCluster);
      expect(round.isPresentation, original.isPresentation);
    });

    test('Phase 2 fields round-trip when the host emits them', () {
      const original = DisplaySnapshot(
        id: 5,
        name: 'shared_fission_bg_XDJAScreenProjection_1',
        width: 1920,
        height: 720,
        densityDpi: 320,
        isDefault: false,
        isPresentation: true,
        isCluster: true,
        role: 'cluster',
        source: 'MARKER',
        confidence: 'HIGH',
        dimReason: 'shadow',
      );
      final round = DisplaySnapshot.fromMap(original.toJson());
      expect(round.role, 'cluster');
      expect(round.source, 'MARKER');
      expect(round.confidence, 'HIGH');
      expect(round.dimReason, 'shadow');
    });

    test(
      'fromMap on legacy host (missing Phase 2 fields) defaults gracefully',
      () {
        // What an ilink@1.5.2 host (before Phase 2) emits — no
        // source/confidence/dimReason keys. Backward-compat is the
        // contract: the SDK keeps working against the old host
        // until every car upgrades.
        final legacy = <String, Object?>{
          'id': 4,
          'name': 'fse',
          'width': 1920,
          'height': 720,
          'densityDpi': 320,
          'isDefault': false,
          'isPresentation': true,
          'isCluster': false,
          'role': 'passenger',
          // no source / confidence / dimReason
        };
        final s = DisplaySnapshot.fromMap(legacy);
        expect(s.role, 'passenger');
        expect(
          s.source,
          'unknown',
          reason: 'missing source field defaults to unknown — safe signal',
        );
        expect(
          s.confidence,
          'medium',
          reason: 'missing confidence field defaults to medium',
        );
        expect(s.dimReason, isNull);
        expect(s.hidden, isFalse);
      },
    );
  });

  group('DisplayFamily subscribe / unsubscribe', () {
    test(
      'subscribe returns a sub_<n> id and routes events to the pusher',
      () async {
        final bridge = _ControllableBridge();
        final fam = DisplayFamily(bridge: bridge);
        final pusher = FakeFamilyEventPusher();

        final sub = await fam.handlers['subscribe']!.execute(
          BridgeCall(
            familyId: 'display',
            op: 'subscribe',
            params: const {},
            session: _session,
            eventPusher: pusher,
          ),
        );
        expect(sub['id'], matches(RegExp(r'^sub_\d+$')));

        bridge.emit(
          const DisplayEvent(kind: DisplayEventKind.added, displayId: 4),
        );
        // Stream is async — yield to let the listener fire.
        await Future<void>.delayed(Duration.zero);
        expect(pusher.events, hasLength(1));
        expect(pusher.events.first.channel, 'display');
        expect(pusher.events.first.payload['type'], 'added');
        expect(pusher.events.first.payload['displayId'], 4);
        await bridge.close();
      },
    );

    test('multiple subscribers all see the same event', () async {
      final bridge = _ControllableBridge();
      final fam = DisplayFamily(bridge: bridge);
      final pusherA = FakeFamilyEventPusher();
      final pusherB = FakeFamilyEventPusher();

      await fam.handlers['subscribe']!.execute(
        BridgeCall(
          familyId: 'display',
          op: 'subscribe',
          params: const {},
          session: _session,
          eventPusher: pusherA,
        ),
      );
      await fam.handlers['subscribe']!.execute(
        BridgeCall(
          familyId: 'display',
          op: 'subscribe',
          params: const {},
          session: _session,
          eventPusher: pusherB,
        ),
      );

      bridge.emit(
        const DisplayEvent(kind: DisplayEventKind.removed, displayId: 5),
      );
      await Future<void>.delayed(Duration.zero);
      expect(pusherA.events, hasLength(1));
      expect(pusherB.events, hasLength(1));
      await bridge.close();
    });

    test('unsubscribe drops the pusher (and idempotent on stale id)', () async {
      final bridge = _ControllableBridge();
      final fam = DisplayFamily(bridge: bridge);
      final pusher = FakeFamilyEventPusher();

      final sub = await fam.handlers['subscribe']!.execute(
        BridgeCall(
          familyId: 'display',
          op: 'subscribe',
          params: const {},
          session: _session,
          eventPusher: pusher,
        ),
      );
      final id = sub['id'] as String;

      final unsub1 = await fam.handlers['unsubscribe']!.execute(
        BridgeCall(
          familyId: 'display',
          op: 'unsubscribe',
          params: {'id': id},
          session: _session,
        ),
      );
      expect(unsub1['ok'], isTrue);

      // Second unsubscribe with same id is a no-op (already gone).
      final unsub2 = await fam.handlers['unsubscribe']!.execute(
        BridgeCall(
          familyId: 'display',
          op: 'unsubscribe',
          params: {'id': id},
          session: _session,
        ),
      );
      expect(unsub2['ok'], isFalse);

      // Events fired after unsubscribe should not reach the pusher.
      bridge.emit(
        const DisplayEvent(kind: DisplayEventKind.changed, displayId: 4),
      );
      await Future<void>.delayed(Duration.zero);
      expect(pusher.events, isEmpty);
      await bridge.close();
    });
  });

  group('DisplayEvent parsing', () {
    test('snapshot kind with displays list', () {
      final evt = DisplayEvent.fromMap(<String, Object?>{
        'type': 'snapshot',
        'displays': [
          {
            'id': 0,
            'name': 'IVI',
            'width': 1920,
            'height': 1200,
            'densityDpi': 240,
            'isDefault': true,
            'isPresentation': false,
            'isCluster': false,
          },
        ],
      });
      expect(evt.kind, DisplayEventKind.snapshot);
      expect(evt.displays, hasLength(1));
      expect(evt.displays!.first.name, 'IVI');
    });

    test('removed kind with displayId only', () {
      final evt = DisplayEvent.fromMap(const <String, Object?>{
        'type': 'removed',
        'displayId': 5,
      });
      expect(evt.kind, DisplayEventKind.removed);
      expect(evt.displayId, 5);
      expect(evt.display, isNull);
    });
  });
}
