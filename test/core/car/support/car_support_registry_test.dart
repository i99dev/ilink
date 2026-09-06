import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/_car_domain/support/car_support_profile.dart';
import 'package:ilink/features/_car_domain/support/car_support_registry.dart';
import 'package:ilink/features/_car_domain/support/hu_vendor.dart';
import 'package:ilink/features/_car_domain/support/integration_tier.dart';
import 'package:ilink/features/_car_domain/support/known_quirk.dart';

void main() {
  group('IntegrationTier', () {
    test('wireValue + displayLabel are stable + unique', () {
      final wires = {for (final t in IntegrationTier.values) t.wireValue};
      expect(wires, hasLength(IntegrationTier.values.length));
      final labels = {for (final t in IntegrationTier.values) t.displayLabel};
      expect(labels, hasLength(IntegrationTier.values.length));
    });

    test('fromWire round-trips every value', () {
      for (final t in IntegrationTier.values) {
        expect(IntegrationTier.fromWire(t.wireValue), t);
      }
    });

    test('fromWire(unknown / null) falls back to unsupported', () {
      expect(IntegrationTier.fromWire(null), IntegrationTier.unsupported);
      expect(
        IntegrationTier.fromWire('not-a-real-tier'),
        IntegrationTier.unsupported,
      );
    });

    test('allowsActuatorDispatch only true for full tier', () {
      expect(IntegrationTier.full.allowsActuatorDispatch, isTrue);
      expect(IntegrationTier.stock.allowsActuatorDispatch, isFalse);
      expect(IntegrationTier.unsupported.allowsActuatorDispatch, isFalse);
    });

    test(
      'allowsReadTelemetry true for full + stock, false for unsupported',
      () {
        expect(IntegrationTier.full.allowsReadTelemetry, isTrue);
        expect(IntegrationTier.stock.allowsReadTelemetry, isTrue);
        expect(IntegrationTier.unsupported.allowsReadTelemetry, isFalse);
      },
    );
  });

  group('HuVendor', () {
    test('wireValue + displayLabel are stable + unique', () {
      final wires = {for (final v in HuVendor.values) v.wireValue};
      expect(wires, hasLength(HuVendor.values.length));
    });

    test('fromWire round-trips every value', () {
      for (final v in HuVendor.values) {
        expect(HuVendor.fromWire(v.wireValue), v);
      }
    });

    test('fromWire(unknown / null) falls back to unknown', () {
      expect(HuVendor.fromWire(null), HuVendor.unknown);
      expect(HuVendor.fromWire('not-a-vendor'), HuVendor.unknown);
    });
  });

  group('CarSupportRegistry.resolve', () {
    const registry = CarSupportRegistry();

    test('exact (vendor, variant) hit returns the precise profile', () {
      final p = registry.resolve(huVendor: HuVendor.byd, variant: 'l8');
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, 'BYD Leopard 8');
    });

    test('l5_nav resolves to its own profile (full), not the '
        '"BYD vehicle (other)" wildcard', () {
      final p = registry.resolve(huVendor: HuVendor.byd, variant: 'l5_nav');
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, 'BYD Leopard 5 Navigator');
    });

    test('sealion6_ev resolves to its own profile (full), not the '
        '"BYD vehicle (other)" wildcard', () {
      final p = registry.resolve(
        huVendor: HuVendor.byd,
        variant: 'sealion6_ev',
      );
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, 'BYD Sealion 06 EV');
    });

    test('l8_dk (drone-kit ROM) resolves to the L8 profile, not the '
        '"BYD vehicle (other)" wildcard', () {
      // Regression for the Diagnostics "Vehicle support" panel showing
      // "BYD vehicle (other)" because the new l8_dk variant had no
      // CarSupportProfile and fell to the BYD wildcard.
      final p = registry.resolve(huVendor: HuVendor.byd, variant: 'l8_dk');
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, 'BYD Leopard 8');
    });

    test('all reverse-engineered Leopard variants resolve to full tier', () {
      const expected = ['l8', 'l8_dk', 'l5', 'l5l', 'l5u', 'l7', 'han_l'];
      for (final v in expected) {
        final p = registry.resolve(huVendor: HuVendor.byd, variant: v);
        expect(p.tier, IntegrationTier.full, reason: 'variant=$v');
      }
    });

    test('BYD model without an exact entry falls to BYD vendor wildcard '
        '(full — BYD car-control is universal across DiLink trims)', () {
      final p = registry.resolve(huVendor: HuVendor.byd, variant: 'seal');
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, contains('BYD vehicle'));
    });

    test('every BYD variant resolves to full tier (no per-profile split)', () {
      const bydVariants = [
        'l8',
        'l5',
        'l5l',
        'l5u',
        'l7',
        'han_l',
        'song_plus',
        'song_pro',
        'qin_l',
        'qin_plus',
        '5f',
        'seal',
        '',
        'some_future_byd',
      ];
      for (final v in bydVariants) {
        final p = registry.resolve(huVendor: HuVendor.byd, variant: v);
        expect(p.tier, IntegrationTier.full, reason: 'BYD variant=$v');
      }
    });

    test('vendor-wildcard resolves to stock tier for every non-BYD vendor', () {
      const vendors = [
        HuVendor.yuanfeng,
        HuVendor.desay,
        HuVendor.liangshan,
        HuVendor.shinco,
        HuVendor.hk,
        HuVendor.acloud,
        HuVendor.nwd,
      ];
      for (final v in vendors) {
        final p = registry.resolve(huVendor: v, variant: '');
        expect(p.tier, IntegrationTier.stock, reason: 'vendor=$v');
      }
    });

    test('unknown vendor → unknownVehicle sentinel', () {
      final p = registry.resolve(huVendor: HuVendor.unknown, variant: '');
      expect(identical(p, CarSupportProfile.unknownVehicle), isTrue);
      expect(p.tier, IntegrationTier.unsupported);
    });

    test(
      'unknown vendor + recognised variant still returns unknownVehicle',
      () {
        final p = registry.resolve(huVendor: HuVendor.unknown, variant: 'l8');
        expect(identical(p, CarSupportProfile.unknownVehicle), isTrue);
      },
    );

    test(
      'Yuanfeng + han_l carries the window-close quirks for both fronts',
      () {
        final p = registry.resolve(
          huVendor: HuVendor.yuanfeng,
          variant: 'han_l',
        );
        expect(p.quirks.map((q) => q.actionId).toSet(), {
          'window.fl.close',
          'window.fr.close',
        });
        expect(
          p.quirks.every((q) => q.severity == QuirkSeverity.warning),
          isTrue,
        );
      },
    );

    test('Yuanfeng vendor-wildcard does NOT carry han_l-specific quirks', () {
      final p = registry.resolve(huVendor: HuVendor.yuanfeng, variant: '');
      expect(p.quirks, isEmpty);
    });
  });

  group('CarSupportRegistry.all', () {
    const registry = CarSupportRegistry();

    test('contains a vendor-wildcard row for every non-unknown vendor', () {
      final vendorsWithWildcard = registry
          .all()
          .where((p) => p.variant.isEmpty)
          .map((p) => p.huVendor)
          .toSet();
      for (final v in HuVendor.values) {
        if (v == HuVendor.unknown) continue;
        expect(
          vendorsWithWildcard.contains(v),
          isTrue,
          reason: 'missing wildcard for $v',
        );
      }
    });

    test('every entry is reachable through resolve()', () {
      // The resolution rules say exact-variant beats wildcard; this
      // test pins that each declared exact-variant row is actually
      // returned for its (vendor, variant) — guards against someone
      // putting a wildcard above an exact row in _entries and
      // shadowing it permanently.
      for (final p in registry.all()) {
        if (p.variant.isEmpty) continue;
        final resolved = registry.resolve(
          huVendor: p.huVendor,
          variant: p.variant,
        );
        expect(
          identical(resolved, p),
          isTrue,
          reason: 'shadowed: ${p.huVendor}/${p.variant}',
        );
      }
    });

    test('unknownVehicle sentinel never appears inside .all()', () {
      // The sentinel is constructor-only — it must not be a real row.
      expect(
        registry.all().any(
          (p) => identical(p, CarSupportProfile.unknownVehicle),
        ),
        isFalse,
      );
    });
  });
}
