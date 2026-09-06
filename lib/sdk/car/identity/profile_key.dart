/// Five-tuple identity that uniquely keys a [CarProfile] across
/// brands, firmware generations, hardware trims, and sub-trims.
///
/// **Why 5-axis** — two adapters can share the same hardware trim
/// but behave differently because of the framework version they
/// run against (the classic case: BYD DiLink 5.0 vs 5.1 register
/// push callbacks differently). Encoding `firmwareVersion` as a
/// first-class axis lets the runtime pick the right adapter
/// without leaking version checks into call sites. See
/// `docs/sdk/identity.md` for the full rationale.
///
/// Mirror of `android/.../car/ProfileKey.kt`. Empty-string slots
/// are valid and represent aggregate fallback rows on the backend.
/// The host computes the active key from `getprop` signals +
/// framework reflection — the Dart side only ever consumes it.
library;

import 'package:flutter/foundation.dart' show immutable;

import '../brand.dart';

@immutable
class ProfileKey {
  const ProfileKey({
    this.brand = CarBrand.byd,
    required this.firmwareVersion,
    this.modelName = '',
    this.subTrim = '',
    this.fingerprint = '',
  });

  /// Brand selector. `CarBrand.byd` by default (the only adapter
  /// shipping today). Geely / NIO / Tesla land alongside without
  /// retro-fitting consumers — they just publish their own profile
  /// database keyed by this brand value.
  final CarBrand brand;

  /// Framework generation — for BYD: `dilink_5_0` / `dilink_5_1` /
  /// `dilink_8_x` / `unknown`. Always populated; the detector falls
  /// back to `unknown` rather than empty.
  ///
  /// **Naming:** underscores over dots (`dilink_5_1`, not
  /// `dilink_5.1`) so the value is safe in filenames + URLs +
  /// log-aggregator tags.
  final String firmwareVersion;

  /// Trim id (`l5` / `l8` / `l5l` / ...). Empty for the
  /// firmware-generation default fallback row.
  final String modelName;

  /// Hardware sub-trim wire string (`flagship` / `base` / ...).
  /// Empty for the trim-level aggregate row.
  final String subTrim;

  /// `ro.build.fingerprint` exactly as Android reports it (or the
  /// brand-equivalent fingerprint). Empty for the sub-trim
  /// aggregate.
  final String fingerprint;

  /// Sentinel — used by the provider when the platform-channel call
  /// fails (dev runner, web, non-Android) so consumers always see a
  /// well-formed key.
  static const ProfileKey unknown = ProfileKey(
    brand: CarBrand.unknown,
    firmwareVersion: 'unknown',
  );

  /// Wire shape — JSON object the platform channel + backend both
  /// consume. Stable field order so output is deterministic.
  ///
  /// **Field names on the wire** match Kotlin's `ProfileKey.kt`
  /// (`dilinkFamily`, `variantId`) — that's the canonical wire
  /// vocabulary, not a back-compat alias. The Dart side uses
  /// [firmwareVersion] + [modelName] internally because those names
  /// generalise across brands (Geely won't have "DiLink"); the wire
  /// stays aligned with Kotlin until both sides rename in lockstep.
  Map<String, String> toJson() => <String, String>{
    'brand': brand.wire,
    'dilinkFamily': firmwareVersion,
    'variantId': modelName,
    'subTrim': subTrim,
    'fingerprint': fingerprint,
  };

  factory ProfileKey.fromJson(Map<String, Object?> m) => ProfileKey(
    brand: CarBrand.fromWire((m['brand'] as String?) ?? 'byd'),
    firmwareVersion: (m['dilinkFamily'] as String?) ?? 'unknown',
    modelName: (m['variantId'] as String?) ?? '',
    subTrim: (m['subTrim'] as String?) ?? '',
    fingerprint: (m['fingerprint'] as String?) ?? '',
  );

  ProfileKey copyWith({
    CarBrand? brand,
    String? firmwareVersion,
    String? modelName,
    String? subTrim,
    String? fingerprint,
  }) => ProfileKey(
    brand: brand ?? this.brand,
    firmwareVersion: firmwareVersion ?? this.firmwareVersion,
    modelName: modelName ?? this.modelName,
    subTrim: subTrim ?? this.subTrim,
    fingerprint: fingerprint ?? this.fingerprint,
  );

  @override
  bool operator ==(Object other) =>
      other is ProfileKey &&
      other.brand == brand &&
      other.firmwareVersion == firmwareVersion &&
      other.modelName == modelName &&
      other.subTrim == subTrim &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode =>
      Object.hash(brand, firmwareVersion, modelName, subTrim, fingerprint);

  @override
  String toString() =>
      'ProfileKey(${brand.wire}/$firmwareVersion/$modelName/$subTrim/$fingerprint)';
}
