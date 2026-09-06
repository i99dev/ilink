/// Single source of truth for "what tier of integration are we on this
/// car right now". Combines the boot-time [HuVendorDetector] +
/// [ModelDetector] outputs with the static [CarSupportRegistry] to
/// produce the active [CarSupportProfile].
///
/// Consumers wire to [carSupportProfileProvider] directly — never to
/// the underlying detector or registry — so the indirection layer
/// stays one provider deep and tests can override a single seam.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/brands/byd/identity/byd_model_detector.dart';
import 'car_support_profile.dart';
import 'car_support_registry.dart';
import 'hu_vendor_detector.dart';
import 'known_quirk.dart';

/// Process-wide registry. Currently const so a single allocation
/// serves every read; if the registry ever grows runtime overrides
/// (user-pinned profile, A/B), this becomes a `Provider<...>` that
/// holds the mutable state.
final carSupportRegistryProvider = Provider<CarSupportRegistry>(
  (ref) => const CarSupportRegistry(),
);

/// Resolved profile for the active car. Async because both inputs
/// are FutureProviders (one-shot reflective prop reads); after the
/// first resolve the value is cached for the rest of the session.
///
/// `.autoDispose` so re-opening Diagnostics gets a fresh resolution
/// — the underlying detectors cache too, so the cost of the
/// re-evaluation is one map lookup, not a re-probe. Pairs with the
/// matching `.autoDispose` on `launcherPrivilegeStatusProvider` —
/// both reflect what's true RIGHT NOW on the HU when the user opens
/// the Diagnostics page, not what was true at app boot.
///
/// Tests override one of three seams:
///   1. [carSupportRegistryProvider] — swap the registry impl.
///   2. [huVendorProvider] — pin the detected vendor.
///   3. [modelDetectorProvider] — pin the detected ModelId.
final carSupportProfileProvider = FutureProvider.autoDispose<CarSupportProfile>(
  (ref) async {
    final registry = ref.watch(carSupportRegistryProvider);
    final results = await (
      ref.watch(huVendorProvider.future),
      ref.watch(modelDetectorProvider.future),
    ).wait;
    final vendor = results.$1;
    final model = results.$2;
    // ModelId.variant is the finest-grained id (`l8`, `han_l`, ...);
    // we use the empty string as the wildcard-row signal so the
    // registry's vendor-wildcard fallback fires when the variant is
    // unknown. ModelId.variant is null when detection didn't resolve
    // a known trim, so coerce to '' here.
    return registry.resolve(huVendor: vendor, variant: model.variant ?? '');
  },
);

/// Sync fallback for callers that can't await the FutureProvider
/// (boot-time gates, pre-frame UI). Returns the unknown sentinel until
/// the future settles, then the resolved profile. Most consumers
/// should prefer [carSupportProfileProvider]; this is the escape
/// hatch.
final carSupportProfileSnapshotProvider = Provider<CarSupportProfile>((ref) {
  return ref
          .watch(carSupportProfileProvider)
          .maybeWhen(data: (p) => p, orElse: () => null) ??
      CarSupportProfile.unknownVehicle;
});

/// Per-action quirk lookup. Family-style provider keyed on the
/// action id (`window.fl.close`, `seat.heat.driver`, etc.) so feature
/// tiles can surface a warning badge inline without each tile having
/// to reach into the full CarSupportProfile.
///
/// **Informational only** — the registry's quirks are advisory.
/// Action dispatch decisions stay with [CarCommandRouter] consulting
/// the runtime [CarProfile.actionSupport]; quirks attach UX warnings
/// on top of that, never gating it. This is the seam that turns
/// Dudu's per-model warning surface ("Han EV may not fully close —
/// wait 5 min") into renderable widget state without changing what
/// the dispatcher does.
///
/// Returns null when no quirk applies — the common case.
final actionQuirkProvider = Provider.family<KnownQuirk?, String>((
  ref,
  actionId,
) {
  final profile = ref.watch(carSupportProfileSnapshotProvider);
  return profile.quirkFor(actionId);
});
