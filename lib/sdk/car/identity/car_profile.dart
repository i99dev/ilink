/// The single object both gates ([CarCommandRouter] for actions; the
/// mini-app catalog filter for capabilities) consult to answer
/// "what works on this car right now". Resolved by the host's
/// `CapabilityRegistry` over a 5-tier fallback chain so even
/// unidentified cars get a usable answer.
///
/// Mirror of `android/.../car/CarProfile.kt`. Constructed from the
/// platform channel response; consumers never build one by hand.
library;

import 'package:flutter/foundation.dart' show immutable;

import 'profile_key.dart';
import 'vehicle_capability.dart';

/// Per-action support classification — what [CarCommandRouter]
/// consults before dispatching. Mirror of the host-side
/// `CarActionSupport.Support` enum.
enum CarActionSupport {
  supported,
  unsupported,

  /// Static seed says we don't know — try, let the daemon authority
  /// decide, fold the result back into the probe (next sync).
  unknownAssumeSupported;

  static CarActionSupport fromWire(String? s) {
    switch (s) {
      case 'SUPPORTED':
        return CarActionSupport.supported;
      case 'UNSUPPORTED':
        return CarActionSupport.unsupported;
      case 'UNKNOWN_ASSUME_SUPPORTED':
        return CarActionSupport.unknownAssumeSupported;
      default:
        return CarActionSupport.unknownAssumeSupported;
    }
  }
}

@immutable
class CarProfile {
  const CarProfile({
    required this.key,
    required this.isFallback,
    required this.fallbackReason,
    required this.friendlyName,
    required this.capabilityBits,
    required this.capabilities,
    required this.capabilitiesSource,
    required this.actionSupport,
  });

  /// The four-tuple identity this profile resolves. Empty-string
  /// slots indicate which fallback tier we landed on.
  final ProfileKey key;

  /// True when the resolver couldn't find a precise (fingerprint-
  /// level) backend match. Both gates use this to decide between
  /// strict enforcement vs. permissive try-with-warning.
  final bool isFallback;

  /// Why the resolver fell back, or null on a precise hit. One of
  /// `unknown_fingerprint` / `unknown_sub_trim` / `unknown_variant` /
  /// `unknown_dilink` / `static_default`.
  final String? fallbackReason;

  /// Friendly UI label — "Leopard 5 Flagship" etc. Carried so the
  /// picker doesn't need to re-derive it from the key.
  final String friendlyName;

  /// Capability bitmask — fed straight to the catalog filter's
  /// [hasAllCapabilities] check. Hot path.
  final int capabilityBits;

  /// Readable capability list (taxonomy order). Both populated
  /// atomically with [capabilityBits] so SDK consumers can pick
  /// either path without round-tripping.
  final List<String> capabilities;

  /// Source of the bitmask. `backend` for a precise overlay hit,
  /// `backend_fallback` for an aggregate row, `static` for the
  /// compiled-in seed.
  final String capabilitiesSource;

  /// Per-action support classification. Sparse — only entries the
  /// host's seed knew about. Anything not in this map defaults to
  /// [CarActionSupport.unknownAssumeSupported] (the daemon stays
  /// the authority).
  final Map<String, CarActionSupport> actionSupport;

  /// Convenience: the support verdict for [actionId], with the
  /// "unknown" default baked in so callers don't repeat the
  /// fallback.
  CarActionSupport supportFor(String actionId) =>
      actionSupport[actionId] ?? CarActionSupport.unknownAssumeSupported;

  /// Empty fallback used when the platform channel fails (dev runner
  /// / non-Android). Conservative: zero caps, no action support →
  /// catalog filter dims everything that needs hardware caps, and
  /// CarCommandRouter falls through to the daemon authority.
  static const CarProfile empty = CarProfile(
    key: ProfileKey.unknown,
    isFallback: true,
    fallbackReason: 'platform_channel_unavailable',
    friendlyName: 'Generic',
    capabilityBits: 0,
    capabilities: [],
    capabilitiesSource: 'static',
    actionSupport: {},
  );

  factory CarProfile.fromMap(Map<String, Object?> m) {
    final keyMap = (m['key'] as Map?)?.cast<String, Object?>() ?? const {};
    final supportRaw =
        (m['actionSupport'] as Map?)?.cast<String, Object?>() ?? const {};
    final support = <String, CarActionSupport>{
      for (final entry in supportRaw.entries)
        entry.key: CarActionSupport.fromWire(entry.value as String?),
    };
    return CarProfile(
      key: ProfileKey.fromJson(keyMap),
      isFallback: (m['isFallback'] as bool?) ?? false,
      fallbackReason: m['fallbackReason'] as String?,
      friendlyName: (m['friendlyName'] as String?) ?? 'Generic',
      // Method-channel marshals Long → int on Dart side.
      capabilityBits: (m['capabilityBits'] as num?)?.toInt() ?? 0,
      capabilities: ((m['capabilities'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      capabilitiesSource: (m['capabilitiesSource'] as String?) ?? 'static',
      actionSupport: support,
    );
  }
}
