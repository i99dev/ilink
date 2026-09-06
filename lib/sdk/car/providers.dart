/// Brand-aware reactive providers — the public surface widgets and
/// mini-apps consume.
///
/// `carCatalogProvider` resolves to the brand-specific catalog
/// loader (BYD → assets/byd/catalog.tsv, Geely → assets/geely/...,
/// etc.). `carClientProvider` (in `client.dart`) routes to the
/// brand-specific adapter implementing reactive reads / writes.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/sdk/car/_transport/car_bridge.dart';
import '../brands/byd/byd_internal_catalog.dart';
import 'brand.dart';
import 'catalog.dart';
import 'client.dart';

/// App-wide [CarCatalog] — loads from the current brand's bundled
/// `.secrets/<brand>/catalog.tsv` + `catalog_meta.yaml` assets.
///
/// Resolves async because brand detection + asset parse take time.
/// Consumers use:
///
/// ```dart
/// final catalog = await ref.read(carCatalogProvider.future);
/// final feature = catalog.feature('Door.DOOR_LOCK_…');
/// ```
final carCatalogProvider = FutureProvider<CarCatalog>((ref) async {
  final brand = await ref.watch(currentBrandProvider.future);
  switch (brand) {
    case CarBrand.byd:
      return ref.watch(bydCatalogProvider.future);
    case CarBrand.geely:
    case CarBrand.nio:
    case CarBrand.tesla:
    case CarBrand.unknown:
      // Adapters not yet implemented — fall back to BYD catalog
      // (which gracefully no-ops if the BYD assets aren't bundled).
      return ref.watch(bydCatalogProvider.future);
  }
});

/// Per-feature reactive provider. Push-driven via the brand client.
///
/// ```dart
/// final lock = ref.watch(featureValueProvider(
///   'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT'
/// ));
/// lock.whenData((v) => Icon(v == 1 ? Icons.lock : Icons.lock_open));
/// ```
final featureValueProvider = StreamProvider.autoDispose.family<int?, String>((
  ref,
  name,
) {
  final client = ref.watch(carClientProvider);
  return client.watch(name);
});

/// Combined record provider — value + the catalog metadata
/// (description, unit, semantics) in one read.
///
/// Useful for UIs that show both a value and its label/unit.
class FeatureLive {
  const FeatureLive({required this.value, this.meta});
  final int? value;
  // [meta] is the matching CarFeature from the catalog; null when
  // the name isn't in the catalog OR the catalog hasn't loaded yet.
  final dynamic /* CarFeature? */ meta;
  bool get isLive => value != null;
}

final featureLiveProvider = StreamProvider.autoDispose
    .family<FeatureLive, String>((ref, name) async* {
      final client = ref.watch(carClientProvider);
      final catalogAsync = ref.watch(carCatalogProvider);
      final meta = catalogAsync.maybeWhen(
        data: (c) => c.feature(name),
        orElse: () => null,
      );
      await for (final v in client.watch(name)) {
        yield FeatureLive(value: v, meta: meta);
      }
    });

/// Host-internal liveness probe — `true` iff the daemon side-loaded
/// service is up and reachable. Polled every 2s; UI surfaces (mic
/// button, action tiles) gate command dispatch on this so taps don't
/// vanish into the void during boot.
///
/// Not a feature value — the daemon-up flag is a transport health
/// signal, separate from the per-feature push stream.
final daemonReadyProvider = StreamProvider<bool>((ref) async* {
  final transport = ref.watch(carBridgeProvider);
  yield false;
  while (true) {
    try {
      final status = await transport.daemonStatus();
      yield status['daemon'] == true;
    } catch (_) {
      yield false;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});
