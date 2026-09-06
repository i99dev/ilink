import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/state/gate.dart';
import 'package:ilink/features/_car_domain/state/gate_snapshot.dart';
import 'package:ilink/sdk/brands/byd/byd_status_labels.dart';
import 'package:ilink/sdk/car/brand.dart';
import 'package:ilink/sdk/car/client.dart';

import '../../../support/fake_car_client.dart';

/// Locks the incremental-rebuild contract of [gateSnapshotProvider]: it
/// must rebuild only when a value it actually tracks changes, using the
/// per-frame changed-name ([CarClient.changes]) to O(1)-skip frames for
/// untracked names and to dedup same-value pushes — while a batch/unknown
/// frame ('') falls back to a full re-check.
void main() {
  late FakeCarClient fake;
  late ProviderContainer container;

  setUp(() {
    fake = FakeCarClient();
    container = ProviderContainer(
      overrides: [
        carClientProvider.overrideWithValue(fake),
        // Pin the brand so its FutureProvider can't rebuild the snapshot
        // mid-test and skew the emission count.
        currentBrandProvider.overrideWith((ref) => CarBrand.byd),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fake.dispose);
  });

  test(
    'rebuilds only on a tracked value change; skips untracked + dedups',
    () async {
      final tracked = bydStatusLabelToCatalog.values.first;
      const untracked = '__not_a_tracked_catalog_name__';

      final gates = <CarGate>[];
      final sub = container.listen(
        gateSnapshotProvider,
        (_, next) => next.whenData(gates.add),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      // Let the initial build + brand resolution settle, then measure deltas.
      await pumpEventQueue();
      final baseline = gates.length;
      expect(
        baseline,
        greaterThan(0),
        reason: 'an initial snapshot should emit',
      );

      // 1. Per-name frame for an untracked name → O(1) skip, no rebuild.
      fake.pushChange(untracked);
      await pumpEventQueue();
      expect(
        gates.length,
        baseline,
        reason: 'an untracked per-name frame must not rebuild the gate',
      );

      // 2. Tracked name with a NEW value → rebuild.
      fake.values[tracked] = 1;
      fake.pushChange(tracked);
      await pumpEventQueue();
      expect(
        gates.length,
        baseline + 1,
        reason: 'a tracked value change must rebuild the gate',
      );

      // 3. Same tracked name, SAME value → deduped, no rebuild.
      fake.pushChange(tracked);
      await pumpEventQueue();
      expect(
        gates.length,
        baseline + 1,
        reason: 'a same-value push must be deduped',
      );

      // 4. Batch/unknown frame ('') after a real change → full re-check rebuilds.
      fake.values[tracked] = 2;
      fake.pushChange();
      await pumpEventQueue();
      expect(
        gates.length,
        baseline + 2,
        reason: 'a batch frame must re-check tracked names and rebuild',
      );
    },
  );
}
