import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/_car_domain/support/car_support_profile.dart';
import 'package:ilink/features/_car_domain/support/car_support_profile_provider.dart';
import 'package:ilink/features/_car_domain/support/hu_vendor.dart';
import 'package:ilink/features/_car_domain/support/hu_vendor_detector.dart';
import 'package:ilink/features/_car_domain/support/integration_tier.dart';
import 'package:ilink/sdk/brands/byd/identity/byd_model_detector.dart';

ProviderContainer _container({HuVendor? vendor, ModelId? model}) {
  final c = ProviderContainer(
    overrides: [
      if (vendor != null) huVendorProvider.overrideWith((_) async => vendor),
      if (model != null) modelDetectorProvider.overrideWith((_) async => model),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

ModelId _modelWith(String? variant, {String dilinkFamily = 'di5.1'}) {
  return ModelId(
    variant: variant,
    dilinkFamily: dilinkFamily,
    bydCarType: null,
    brand: null,
    bodyType: null,
    vehicleId: -1,
    vin: null,
    powerType: -1,
    driverSeat: -1,
  );
}

void main() {
  group('carSupportProfileProvider', () {
    test('byd + l8 resolves to the full-tier Leopard 8 profile', () async {
      final c = _container(vendor: HuVendor.byd, model: _modelWith('l8'));
      final p = await c.read(carSupportProfileProvider.future);
      expect(p.tier, IntegrationTier.full);
      expect(p.displayName, 'BYD Leopard 8');
      expect(p.huVendor, HuVendor.byd);
    });

    test('null variant on a known vendor falls to vendor wildcard', () async {
      // Detector hasn't resolved a trim yet (new ROM, partial prop
      // read). The provider should coerce null → empty string and
      // fall to the BYD vendor-wildcard row, NOT the unknown sentinel.
      // The BYD wildcard is `full`: car-control is universal across BYD
      // DiLink, so even an unresolved BYD trim gets control.
      final c = _container(vendor: HuVendor.byd, model: _modelWith(null));
      final p = await c.read(carSupportProfileProvider.future);
      expect(p.tier, IntegrationTier.full);
      expect(p.huVendor, HuVendor.byd);
    });

    test('unknown vendor + any variant → unknownVehicle sentinel', () async {
      final c = _container(vendor: HuVendor.unknown, model: _modelWith('l8'));
      final p = await c.read(carSupportProfileProvider.future);
      expect(identical(p, CarSupportProfile.unknownVehicle), isTrue);
      expect(p.tier, IntegrationTier.unsupported);
    });

    test('Yuanfeng + han_l carries the window-close quirks', () async {
      final c = _container(
        vendor: HuVendor.yuanfeng,
        model: _modelWith('han_l'),
      );
      final p = await c.read(carSupportProfileProvider.future);
      expect(p.tier, IntegrationTier.stock);
      expect(p.quirks.length, 2);
      expect(p.quirks.map((q) => q.actionId).toSet(), {
        'window.fl.close',
        'window.fr.close',
      });
    });
  });

  group('actionQuirkProvider', () {
    test('returns the matching quirk when one applies', () async {
      final c = _container(
        vendor: HuVendor.yuanfeng,
        model: _modelWith('han_l'),
      );
      // Drain the future so the snapshot provider has data.
      await c.read(carSupportProfileProvider.future);
      final q = c.read(actionQuirkProvider('window.fl.close'));
      expect(q, isNotNull);
      expect(q!.actionId, 'window.fl.close');
    });

    test('returns null when no quirk applies', () async {
      final c = _container(vendor: HuVendor.byd, model: _modelWith('l8'));
      await c.read(carSupportProfileProvider.future);
      // l8 is full-tier with no declared quirks today.
      expect(c.read(actionQuirkProvider('door.lock')), isNull);
    });

    test('returns null while the snapshot is still loading', () {
      final c = ProviderContainer(
        overrides: [
          huVendorProvider.overrideWith((_) {
            return Future.any<HuVendor>([]);
          }),
        ],
      );
      addTearDown(c.dispose);
      // Snapshot collapses to unknownVehicle which has no quirks.
      expect(c.read(actionQuirkProvider('window.fl.close')), isNull);
    });
  });

  group('CarSupportProfile.quirkFor', () {
    test('finds the quirk by exact actionId', () async {
      final c = _container(
        vendor: HuVendor.yuanfeng,
        model: _modelWith('han_l'),
      );
      final profile = await c.read(carSupportProfileProvider.future);
      expect(profile.quirkFor('window.fl.close'), isNotNull);
      expect(profile.quirkFor('window.fr.close'), isNotNull);
      // No quirk for the rear windows on this entry.
      expect(profile.quirkFor('window.rl.close'), isNull);
      expect(profile.quirkFor('door.lock'), isNull);
    });
  });

  group('carSupportProfileSnapshotProvider', () {
    test('settles to unknownVehicle until the future resolves', () async {
      // Arrange a vendor provider that never resolves so the snapshot
      // stays in the "loading" state.
      final c = ProviderContainer(
        overrides: [
          huVendorProvider.overrideWith((_) {
            // Never-resolving Future to pin the loading state.
            return Future.any<HuVendor>([]);
          }),
        ],
      );
      addTearDown(c.dispose);
      final snap = c.read(carSupportProfileSnapshotProvider);
      expect(identical(snap, CarSupportProfile.unknownVehicle), isTrue);
    });

    test('returns the resolved profile after the future settles', () async {
      final c = _container(vendor: HuVendor.byd, model: _modelWith('l5l'));
      // Drain the future so the snapshot has data.
      await c.read(carSupportProfileProvider.future);
      final snap = c.read(carSupportProfileSnapshotProvider);
      expect(snap.tier, IntegrationTier.full);
      expect(snap.displayName, 'BYD Leopard 5 Lidar');
    });
  });
}
