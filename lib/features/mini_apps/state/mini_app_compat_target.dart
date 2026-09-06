/// The ONE place the host builds a [CompatTarget] for the active car.
/// Every launch-gate / catalog-filter consumer reads this provider so
/// the "can this app run here?" inputs can never drift between call
/// sites (single source of truth — same posture as the SDK's
/// `evaluateCompatibility`).
///
/// Inputs, all already resolved elsewhere — assembled here, not
/// re-derived per call site:
///   * `dilinkFamily` — the detected generation (`modelDetector`).
///   * `vehicleCapabilityBits` — the resolved per-trim profile
///     bitmask (`carProfile`); the gate's capability rule is a
///     branchless AND over this.
///   * `bridgeVersion` — the host bridge protocol constant.
///   * `modernWebview` — the **measured** installed-WebView Chromium
///     major (≥ [kEsModuleChromiumFloor] ⇒ ES-module capable), via
///     [webviewChromiumMajorProvider]. This replaces the old
///     `dilinkFamily` proxy (Di5.0 ⇒ always incompatible), which the
///     car-profiler proved wrong: Di5.0 trims (Song PLUS, L5) measure
///     Chromium 95 and run modern ES-module bundles. The generation
///     proxy survives only as the fallback when the version is
///     unmeasurable (unknown ⇒ absent, so the gate still fails closed
///     for any `modernWebview`-requiring app).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/brands/byd/identity/byd_model_detector.dart';
import '../../../sdk/car/identity/car_identity_provider.dart';
import '../bridge/car_bridge_service.dart';
import '../domain/mini_app_compat.dart';
import '../runtime/webview_capability.dart';

/// Fallback only — used when the real WebView Chromium version can't be
/// measured ([webviewChromiumMajorProvider] → null). Generation proxy:
/// Di5.1 ships a modern WebView; Di5.0's floor is unknowable from the
/// generation alone (measured units are Chromium 95, but the proxy can't
/// prove it), so it stays conservative-false; unknown ⇒ null (fail
/// closed). Prefer the measured value; this is the safety net.
bool? _modernWebviewFallbackFor(String dilinkFamily) {
  switch (dilinkFamily) {
    case 'di5.1':
      return true;
    case 'di5.0':
      return false;
    default:
      return null;
  }
}

/// Active-car [CompatTarget]. Resolves once the profile + model
/// detector settle (both cached for the session); rebuild by
/// invalidating those upstream providers after a re-probe. On any
/// upstream failure the empty `CarProfile` / `unknown` dilink flow
/// through unchanged — the gate then fails closed, which is the
/// intended safe default.
final miniAppCompatTargetProvider = FutureProvider<CompatTarget>((ref) async {
  final model = await ref.watch(modelDetectorProvider.future);
  final profile = await ref.watch(carProfileProvider.future);
  final chromiumMajor = await ref.watch(webviewChromiumMajorProvider.future);
  final dilinkFamily = model.dilinkFamily;
  // Measured WebView wins; the generation proxy is only the fallback
  // when the Chromium version is unmeasurable (a measured `false` for an
  // old WebView is still used — `??` only fires on `null`).
  final modernWebview =
      modernWebviewFromChromiumMajor(chromiumMajor) ??
      _modernWebviewFallbackFor(dilinkFamily);
  return CompatTarget(
    dilinkFamily: dilinkFamily,
    vehicleCapabilityBits: profile.capabilityBits,
    vehicleCapabilities: profile.capabilities,
    bridgeVersion: CarBridgeService.kBridgeVersion,
    modernWebview: modernWebview,
  );
});
