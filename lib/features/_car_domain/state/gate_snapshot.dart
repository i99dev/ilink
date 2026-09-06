/// Builds a typed [CarGate] snapshot from the SDK's hot cache.
///
/// Replaces the legacy `carGateProvider` (and its `carStateController`
/// polling chain) with a single push-driven provider sourced entirely
/// from the SDK's per-feature cache. One subscription to
/// [CarClient.changes], one synchronous gate-rebuild per push frame
/// — no per-field StreamProvider allocations, no N+1 daemon polling.
///
/// Consumers that historically read `carGateProvider`:
///   - `car_status_fanout` (mini-app projection + delta predicate)
///
/// All other widgets read individual features via [featureValueProvider].
/// The gate-snapshot exists only for legitimate snapshot-style
/// consumers; per-field consumers should NOT subscribe here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gate.dart';
import '../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../sdk/car/brand.dart';
import '../../../sdk/car/client.dart';

/// Reactive [CarGate] snapshot. Rebuilds on a push frame only when a
/// value this gate actually tracks changed; subscribers see a fresh typed
/// gate without polling.
///
/// The catalog has ~14k names; this gate tracks ~150 (the label map). Each
/// push frame carries the changed name (see [CarClient.changes]), so a
/// frame for an untracked name is skipped in O(1) — no per-frame walk of
/// all 150 labels. A batch/unknown frame ('' name — boot seed, restore,
/// multi-name recompute) falls back to the full walk. Same-value pushes for
/// a tracked name are deduped too, so battery percent ticking once a second
/// doesn't rebuild the doors gate.
final gateSnapshotProvider = StreamProvider<CarGate>((ref) async* {
  final client = ref.watch(carClientProvider);
  final brand = ref
      .watch(currentBrandProvider)
      .maybeWhen(data: (b) => b, orElse: () => CarBrand.byd);
  final labelMap = _labelMapFor(brand);
  // The ~150 catalog names this gate tracks, as a set for O(1) frame
  // filtering against the ~14k-name catalog.
  final trackedNames = labelMap.values.toSet();
  final lastValues = <String, int?>{};

  yield _buildGate(client, labelMap, lastValues);
  await for (final changedName in client.changes()) {
    final bool shouldRebuild;
    if (changedName.isEmpty) {
      // Batch/unknown frame — re-check every tracked name.
      shouldRebuild = _anyTrackedLabelChanged(client, labelMap, lastValues);
    } else if (trackedNames.contains(changedName)) {
      // Tracked per-name frame — O(1) value-change check (dedups a
      // same-value push) instead of re-walking all ~150 labels.
      shouldRebuild = client.value(changedName) != lastValues[changedName];
    } else {
      // Per-name frame for an untracked name — can't affect the gate.
      shouldRebuild = false;
    }
    if (shouldRebuild) yield _buildGate(client, labelMap, lastValues);
  }
});

/// Returns true if any catalog name in [labelMap] has a different
/// current value than the last value we recorded in [lastValues].
/// Side-effect-free; [_buildGate] is responsible for updating
/// [lastValues] when it does emit.
bool _anyTrackedLabelChanged(
  CarClient client,
  Map<String, String> labelMap,
  Map<String, int?> lastValues,
) {
  for (final catalogName in labelMap.values) {
    if (client.value(catalogName) != lastValues[catalogName]) {
      return true;
    }
  }
  return false;
}

/// Brand-routed label-to-catalog map. Each brand contributes its own
/// (BYD shipping today; Geely / NIO / Tesla land their own
/// `<brand>_status_labels.dart` when their adapters arrive).
Map<String, String> _labelMapFor(CarBrand brand) {
  switch (brand) {
    case CarBrand.byd:
    case CarBrand.geely:
    case CarBrand.nio:
    case CarBrand.tesla:
    case CarBrand.unknown:
      return bydStatusLabelToCatalog;
  }
}

CarGate _buildGate(
  CarClient client,
  Map<String, String> labelMap,
  Map<String, int?> lastValues,
) {
  final raw = <String, dynamic>{
    // Connection liveness is host-internal — no catalog name. The
    // 3D / fan-out consumers don't act on it; the daemon-ready
    // gating uses [daemonReadyProvider] directly.
    'adbConnected': false,
    'daemonReady': true,
  };
  labelMap.forEach((label, catalogName) {
    final v = client.value(catalogName);
    lastValues[catalogName] = v;
    if (v != null) raw[label] = v;
  });
  return CarGate.fromRaw(raw);
}
