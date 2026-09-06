/// OEM-brand identification for the multi-brand car SDK.
///
/// The SDK pattern (catalog discovery + push-driven values + typed
/// facades) is brand-agnostic; only the implementation differs.
/// [CarBrand] tags which OEM framework is reachable on the current
/// device, so the runtime can wire the correct
/// [lib/sdk/brands/<brand>/...] adapter.
///
/// To add a new brand:
///   1. Add an enum entry below.
///   2. Add detection logic to [detectBrand] (typically a
///      `Class.forName` probe of the OEM's framework class via the
///      Kotlin host bridge).
///   3. Implement the adapter under
///      `lib/sdk/brands/<brand>/<brand>_catalog.dart` +
///      `lib/sdk/brands/<brand>/<brand>_client.dart`.
///   4. Wire the adapter selection in `lib/sdk/car/client.dart` →
///      `carClientProvider`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/sdk/car/_transport/car_bridge.dart';
import 'package:ilink/sdk/car/_transport/car_transport.dart';

enum CarBrand {
  /// BYD's `android.hardware.bydauto.*` framework — DiLink5.0+
  /// (Han / Tang / Leopard / Yangwang / etc).
  byd,

  /// Geely's framework — placeholder for the next adapter.
  /// Detection logic + adapter not yet implemented.
  geely,

  /// NIO's framework — placeholder.
  nio,

  /// Tesla's framework — placeholder.
  tesla,

  /// Generic Android — no OEM framework reachable. SDK stays
  /// inert; widgets that depend on car features render their
  /// "not supported" branch.
  unknown;

  /// Stable wire string for the JSON/protobuf representation of a
  /// brand. Lowercase snake_case so the value is safe in filenames
  /// (e.g. `assets/byd/dilink_5_1/car_table.pb.enc`), URLs, and
  /// log-aggregator tags. Round-trips through [fromWire].
  String get wire => name;

  /// Inverse of [wire]. Unknown values fall back to
  /// [CarBrand.unknown] rather than throwing so an unexpected
  /// backend value doesn't crash boot.
  static CarBrand fromWire(String s) {
    for (final b in CarBrand.values) {
      if (b.name == s) return b;
    }
    return CarBrand.unknown;
  }
}

/// Best-effort brand detection. Cached by the provider; runs once
/// at app boot. Returns [CarBrand.unknown] when no known framework
/// class is reachable.
///
/// NOTE: This currently always returns [CarBrand.byd] because the
/// host bridge doesn't yet expose a `detectBrand` method. The next
/// step is wiring a Kotlin handler that does the `Class.forName`
/// probes per brand and reports back. For now BYD is hardcoded
/// because the only physical car we have access to is a Leopard 8.
Future<CarBrand> detectBrand(CarTransport _) async {
  // TODO(multi-brand): wire host-side probe via a new MethodChannel
  //   handler that does Class.forName checks for each brand's
  //   framework class. Until that lands, return BYD unconditionally
  //   — the runtime catalog load will still fail gracefully if the
  //   BYD framework is absent (registry stays empty, UIs render
  //   their not-supported branch).
  return CarBrand.byd;
}

/// App-wide singleton — detected once at boot, stable thereafter.
final currentBrandProvider = FutureProvider<CarBrand>((ref) async {
  return detectBrand(ref.watch(carBridgeProvider));
});
