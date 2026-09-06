/// Vehicle / hardware capabilities — the host's mirror of the SDK's
/// canonical taxonomy in `ilink-sdk/src/types/vehicle-capabilities.ts`.
///
/// **Bit positions are derived from list order — never reorder.** New
/// entries append; removals leave a gap (replace with a tombstone
/// string like `'_removed'` to preserve indices). The SDK's drift
/// check (`scripts/check-capability-drift.mjs`) parses this file
/// looking for `kVehicleCapabilities = <String>[...]`; rename only
/// in coordination with the script.
///
/// Three orthogonal axes the catalog reasons over:
///   * `permissions`           — does the *host* implement the family?
///   * `requiredPermissions`   — is the *publisher* allowed to ship it?
///   * `requiredCapabilities`  — does the *physical car* support it?
///
/// This file owns the third axis on the host.
library;

const List<String> kVehicleCapabilities = <String>[
  'display.read',
  'pkg.read',
  'pkg.launch.ivi',
  'pkg.launch.passenger',
  'pkg.launch.cluster.pixel',
  'pkg.launch.cluster.icons',
  'pkg.launch.dishare',
  'surface.write.ivi',
  'surface.write.passenger',
  'surface.write.cluster',
  'cursor.write',
  'gesture.dispatch',
  'ac.get',
  'ac.set',
  'door.set',
  'window.set',
];

/// Pack a list of capability strings into a single bitmask. Unknown
/// strings are silently skipped — defensive against newer SDKs
/// declaring caps the host doesn't yet know about. The catalog merge
/// uses this on every app per render; keep it allocation-free.
///
/// Named to mirror the SDK's `bitsFromCapabilities`
/// (`ilink-sdk/src/types/vehicle-capabilities.ts`) so the
/// capability-bitmask helpers carry one identifier across TS, Python,
/// and Dart — no per-language alias to drift.
int bitsFromCapabilities(Iterable<String> caps) {
  var bits = 0;
  for (final cap in caps) {
    final idx = kVehicleCapabilities.indexOf(cap);
    if (idx >= 0) bits |= 1 << idx;
  }
  return bits;
}

/// Inverse — turn a bitmask back into the canonical capability list,
/// in taxonomy order (deterministic regardless of how bits were set).
List<String> capabilitiesFromBits(int bits) {
  final out = <String>[];
  for (var i = 0; i < kVehicleCapabilities.length; i++) {
    if ((bits & (1 << i)) != 0) out.add(kVehicleCapabilities[i]);
  }
  return out;
}

/// `app.required ⊆ vehicle.has`. Single bitmask AND, branchless. The
/// catalog filter calls this once per app per render — must stay
/// O(1).
bool hasAllCapabilities(int vehicleBits, int requiredBits) =>
    (vehicleBits & requiredBits) == requiredBits;
