// Host-side contract test for the mini-app vehicle-compat gate.
//
// This is a VERBATIM port of the SDK's case table in
// `ilink-sdk/src/types/__tests__/compat.test.ts`. The three
// implementations of `evaluateCompatibility` — SDK (TS), backend
// (Python), host (this Dart port) — must never disagree about whether
// an app is shown/launched, so they share one case table. Any rule
// change must land in lockstep across all three (see
// `ilink-sdk/MANIFEST-COMPAT-ENFORCEMENT.md`).
//
// One SDK case is intentionally NOT ported: `CompatTargetSchema is
// strict (rejects unknown keys)`. That guards a zod runtime schema
// (untrusted JSON → typed object). The host never parses a
// `CompatTarget` from the wire — it is assembled in-process by
// `miniAppCompatTargetProvider` from already-typed `CarProfile` /
// model-detector facts — so a strict-key check has no host analogue.

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_compat.dart';
import 'package:ilink/sdk/car/identity/vehicle_capability.dart';

void main() {
  // Realistic targets, modelled on the verified fleet:
  //   * Di5.0 (L5 / Song Plus): old WebView, BYD container → no
  //     usable cluster, bridge v2.
  //   * Di5.1 (L8 / L5L): modern WebView, XDJA container → cluster.
  //   * unknown: dev runner / non-BYD — nothing proven.
  final di50 = CompatTarget(
    dilinkFamily: 'di5.0',
    vehicleCapabilityBits: bitsFromCapabilities(const [
      'display.read',
      'pkg.read',
      'pkg.launch.ivi',
      'pkg.launch.passenger',
      'surface.write.ivi',
      'surface.write.passenger',
    ]),
    bridgeVersion: '2.0.0',
    modernWebview: false,
  );
  final di51 = CompatTarget(
    dilinkFamily: 'di5.1',
    vehicleCapabilityBits: bitsFromCapabilities(const [
      'display.read',
      'pkg.read',
      'pkg.launch.ivi',
      'pkg.launch.passenger',
      'pkg.launch.cluster.pixel',
      'surface.write.ivi',
      'surface.write.passenger',
      'surface.write.cluster',
    ]),
    bridgeVersion: '2.0.0',
    modernWebview: true,
  );
  const unknown = CompatTarget(dilinkFamily: 'unknown');

  group('evaluateCompatibility', () {
    test('no requires → runs on every car (weather-ahead pattern)', () {
      // SDK `mkApp()` (no requires) ⇒ host catalog parse yields a
      // null `requires` (MiniAppRequires.fromJson(null)).
      for (final t in [di50, di51, unknown]) {
        expect(evaluateCompatibility(null, t).ok, isTrue);
      }
    });

    test('cluster app: hidden on Di5.0, shown on Di5.1', () {
      const app = MiniAppRequires(
        vehicleCapabilities: ['surface.write.cluster'],
      );
      final r50 = evaluateCompatibility(app, di50);
      expect(r50.ok, isFalse);
      expect(
        r50.reasons.first.code,
        CompatReasonCode.missingVehicleCapabilities,
      );
      expect(r50.reasons.first.detail, contains('surface.write.cluster'));
      expect(evaluateCompatibility(app, di51).ok, isTrue);
      expect(evaluateCompatibility(app, unknown).ok, isFalse);
    });

    test('dilink allow-list gates by generation; unknown fails closed', () {
      const app = MiniAppRequires(dilink: ['di5.1']);
      expect(isCompatible(app, di51), isTrue);
      expect(isCompatible(app, di50), isFalse);
      expect(isCompatible(app, unknown), isFalse);
      expect(
        evaluateCompatibility(app, di50).reasons.first.code,
        CompatReasonCode.dilinkUnsupported,
      );
    });

    test('modernWebview: fails closed when host fact is false or absent', () {
      const app = MiniAppRequires(modernWebview: true);
      expect(isCompatible(app, di51), isTrue);
      expect(isCompatible(app, di50), isFalse); // modernWebview:false
      // modernWebview absent on target → fail closed (assume old).
      expect(
        isCompatible(app, const CompatTarget(dilinkFamily: 'di5.1')),
        isFalse,
      );
      expect(
        evaluateCompatibility(app, di50).reasons.first.code,
        CompatReasonCode.webviewTooOld,
      );
    });

    test('minBridge: numeric semver-ish compare, missing fails closed', () {
      const app = MiniAppRequires(minBridge: '2.0.0');
      expect(
        isCompatible(
          app,
          const CompatTarget(dilinkFamily: 'di5.1', bridgeVersion: '2.0.0'),
        ),
        isTrue,
      );
      expect(
        isCompatible(
          app,
          const CompatTarget(dilinkFamily: 'di5.1', bridgeVersion: '2.1.0'),
        ),
        isTrue,
      );
      expect(
        isCompatible(
          app,
          const CompatTarget(dilinkFamily: 'di5.1', bridgeVersion: '2.0'),
        ),
        isTrue,
      );
      expect(
        isCompatible(
          app,
          const CompatTarget(dilinkFamily: 'di5.1', bridgeVersion: '1.6.0'),
        ),
        isFalse,
      );
      // bridgeVersion absent → fail closed.
      expect(
        isCompatible(app, const CompatTarget(dilinkFamily: 'di5.1')),
        isFalse,
      );
      expect(
        evaluateCompatibility(
          app,
          const CompatTarget(dilinkFamily: 'di5.1', bridgeVersion: '1.6.0'),
        ).reasons.first.code,
        CompatReasonCode.bridgeTooOld,
      );
    });

    test('forward-compat: a newer requires.schema fails closed everywhere', () {
      const app = MiniAppRequires(schema: 999, dilink: ['di5.1']);
      final r = evaluateCompatibility(app, di51); // would otherwise pass
      expect(r.ok, isFalse);
      expect(r.reasons, hasLength(1));
      expect(r.reasons.first.code, CompatReasonCode.unsupportedRequiresSchema);
    });

    test('aggregates every failed gate, not just the first', () {
      const app = MiniAppRequires(
        dilink: ['di5.1'],
        vehicleCapabilities: ['surface.write.cluster'],
        modernWebview: true,
        minBridge: '3.0.0',
      );
      final r = evaluateCompatibility(app, di50);
      expect(r.ok, isFalse);
      final codes = r.reasons.map((x) => x.code).toSet();
      expect(codes, {
        CompatReasonCode.bridgeTooOld,
        CompatReasonCode.dilinkUnsupported,
        CompatReasonCode.missingVehicleCapabilities,
        CompatReasonCode.webviewTooOld,
      });
    });

    test('accepts the readable capability list when bits are absent', () {
      const app = MiniAppRequires(
        vehicleCapabilities: ['surface.write.cluster'],
      );
      const listTarget = CompatTarget(
        dilinkFamily: 'di5.1',
        vehicleCapabilities: ['surface.write.cluster', 'display.read'],
      );
      expect(isCompatible(app, listTarget), isTrue);
    });
  });
}
