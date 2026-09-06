/// One-shot HU vendor detector. Reads the same `ilink/model_detector`
/// platform channel the existing [ModelDetector] uses, classifies into
/// a [HuVendor] enum, caches forever.
///
/// Distinct provider from `modelDetectorProvider` because:
///   * It only needs three props (brand / manufacturer / fingerprint
///     plus the BYD-specific outswver as a positive signal); reading
///     them through the same channel keeps the Kotlin surface small.
///   * Detection-failure semantics differ: when the channel is
///     unreachable we want [HuVendor.unknown] so the registry falls
///     to the unknown-vehicle sentinel; ModelDetector returns its own
///     [ModelId.unknown] which is variant-shaped.
///
/// The classification rules are CONSERVATIVE — a positive vendor match
/// requires either an explicit brand string or a vendor-specific
/// system-property keyspace. When neither is present we return
/// [HuVendor.unknown] rather than guessing; the registry's vendor-
/// wildcard rows take over from there.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/logging/logger.dart';
import 'hu_vendor.dart';

const _channel = MethodChannel('ilink/model_detector');

class HuVendorDetector {
  HuVendorDetector._();

  static HuVendor? _cached;
  static const _log = Logger('HuVendorDetector');

  /// Read once, cache forever. Subsequent calls are O(1).
  static Future<HuVendor> detect() async {
    if (_cached != null) return _cached!;
    if (!Platform.isAndroid) {
      return _cached = HuVendor.unknown;
    }
    Map<String, String?> raw;
    try {
      final result = await _channel.invokeMapMethod<String, String?>(
        'readVendorProps',
      );
      raw = result ?? const <String, String?>{};
    } on PlatformException catch (e) {
      _log.w('readVendorProps failed: ${e.code} ${e.message}');
      raw = const <String, String?>{};
    } on MissingPluginException {
      // Channel not registered (test harness, dev fast-replace before
      // PlatformPlugins.installAll fires). Stay unknown so the
      // registry's fallback sentinel takes over.
      raw = const <String, String?>{};
    }
    return _cached = classify(raw);
  }

  /// Test-only: install a synthetic vendor without going through the
  /// platform channel. Cleared by [resetForTesting].
  @visibleForTesting
  static void debugSetCached(HuVendor vendor) {
    _cached = vendor;
  }

  @visibleForTesting
  static void resetForTesting() {
    _cached = null;
  }

  /// Pure classification — same map shape ModelDetector consumes,
  /// returns the resolved [HuVendor]. Visible for testing so the
  /// rules can be exercised against curated fixtures without
  /// touching the channel.
  ///
  /// Decision order (first hit wins, conservative throughout):
  ///
  /// 1. **BYD positive markers** — presence of any BYD-namespaced
  ///    prop (`apps.setting.product.outswver`, `persist.sys.byd.*`,
  ///    `ro.byd.*`) implies BYD's first-party DiLink stack. This is
  ///    the most reliable signal — aftermarket vendors don't write
  ///    these.
  /// 2. **brand / manufacturer string** — checked case-insensitively
  ///    against the known vendor names. Catches vendors that write
  ///    their name into `ro.product.brand` (Yuanfeng, Desay,
  ///    Liangshan).
  /// 3. **fingerprint substring** — last-resort check for
  ///    aftermarket builds that overwrite `ro.product.brand` to
  ///    "BYD" (to spoof OEM appearance) but leave the build chain
  ///    fingerprint alone. Matches the same vendor names against
  ///    the fingerprint string.
  /// 4. **Fallthrough** — [HuVendor.unknown]. The registry's
  ///    fail-closed sentinel takes over.
  @visibleForTesting
  static HuVendor classify(Map<String, String?> raw) {
    // Step 1 — BYD positive markers. Any BYD-namespaced prop is
    // sufficient because aftermarket vendors don't carry them.
    final outsw = raw['apps.setting.product.outswver']?.trim();
    final bydDefaultName = raw['persist.sys.byd.default_name']?.trim();
    final bydSplitScreen = raw['ro.byd.ui.splitscreen']?.trim();
    final bydPlatformized = raw['ro.byd.ui.platformized']?.trim();
    if ((outsw ?? '').isNotEmpty ||
        (bydDefaultName ?? '').isNotEmpty ||
        (bydSplitScreen ?? '').isNotEmpty ||
        (bydPlatformized ?? '').isNotEmpty) {
      return HuVendor.byd;
    }

    // Step 2 — brand / manufacturer match.
    final brand = (raw['ro.product.brand'] ?? '').toLowerCase();
    final manufacturer = (raw['ro.product.manufacturer'] ?? '').toLowerCase();
    final byBrand =
        _matchVendorString(brand) ?? _matchVendorString(manufacturer);
    if (byBrand != null) return byBrand;

    // Step 3 — fingerprint last-resort.
    final fingerprint = (raw['ro.build.fingerprint'] ?? '').toLowerCase();
    final byFingerprint = _matchVendorString(fingerprint);
    if (byFingerprint != null) return byFingerprint;

    return HuVendor.unknown;
  }

  /// Substring-match a vendor name out of a free-form string. Only
  /// matches the names we have positive coverage for in the
  /// registry — extending the registry to a new vendor is what
  /// adds the matching name here. Order matters when names are
  /// substrings of each other (none today; comment kept for
  /// future-proofing).
  static HuVendor? _matchVendorString(String s) {
    if (s.isEmpty) return null;
    if (s.contains('byd')) return HuVendor.byd;
    if (s.contains('yuanfeng')) return HuVendor.yuanfeng;
    if (s.contains('desay')) return HuVendor.desay;
    if (s.contains('liangshan')) return HuVendor.liangshan;
    if (s.contains('shinco')) return HuVendor.shinco;
    if (s.contains('acloud')) return HuVendor.acloud;
    if (s.contains('nwd')) return HuVendor.nwd;
    // 'hk' is too short / collision-prone — only matched if it's a
    // standalone token (manufacturer == "hk") rather than a
    // substring (would otherwise hit "hkmc", "shake", etc.).
    if (s == 'hk') return HuVendor.hk;
    return null;
  }
}

/// One-shot Riverpod accessor. The future resolves on the first read;
/// every consumer afterwards gets the cached value via `requireValue`.
final huVendorProvider = FutureProvider<HuVendor>((ref) async {
  return HuVendorDetector.detect();
});
