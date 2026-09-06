/// Host port of the SDK's `evaluateCompatibility()` — "can this
/// mini-app run on THIS car?". A line-by-line mirror of
/// `ilink-sdk/src/types/compat.ts` (rule order, reason codes,
/// fail-closed semantics) so the backend catalog (Python), the SDK
/// CLI (TS), and this host (Dart) can never disagree about whether an
/// app is shown/launched. Defense-in-depth: a stale catalog cache
/// must not launch an app the active car can't run.
///
/// **Fail-closed by construction.** Anything we cannot positively
/// confirm — an unknown DiLink, an absent host fact, a
/// `requires.schema` newer than this build — resolves to
/// *incompatible*. Hiding a working app is recoverable; launching a
/// broken one on a moving car is not.
///
/// Contract pinned by `mini_app_compat_test.dart`, which ports the
/// SDK's `compat.test.ts` case table verbatim. Any rule change must
/// land in lockstep with the SDK + backend (see
/// `ilink-sdk/MANIFEST-COMPAT-ENFORCEMENT.md`).
library;

import '../../../sdk/car/identity/vehicle_capability.dart';

/// Mirror of the SDK `REQUIRES_SCHEMA`. Bump only in lockstep with the
/// SDK when a new `requires.*` rule is added. A manifest declaring a
/// higher schema carries a gate this build can't evaluate ⇒
/// fail-closed (`unsupported_requires_schema`).
const int kRequiresSchema = 1;

/// Hard compatibility requirements declared by a mini-app's manifest
/// (`requires`). Mirror of the SDK `MiniAppRequiresSchema`. Every
/// field is optional; the whole block absent ⇒ "runs on any car".
/// Lenient parse (passthrough): unknown keys are ignored, never throw
/// — forward-compat is handled by the [schema] fail-closed check, not
/// by parse errors.
class MiniAppRequires {
  const MiniAppRequires({
    this.schema = kRequiresSchema,
    this.dilink,
    this.vehicleCapabilities,
    this.modernWebview,
    this.minBridge,
  });

  /// Schema version of this block. Defaults to the current schema
  /// when omitted (matches the SDK's zod `.default`).
  final int schema;

  /// DiLink generation allow-list, e.g. `['di5.1']`. A car whose
  /// `dilinkFamily` is not listed (including `'unknown'`) fails.
  final List<String>? dilink;

  /// Vehicle-hardware capabilities the car MUST advertise (canonical
  /// `kVehicleCapabilities` vocabulary). Branchless bitmask subset.
  final List<String>? vehicleCapabilities;

  /// `true` ⇒ the app needs a modern WebView (ES modules; Chromium ≥
  /// `kEsModuleChromiumFloor` = 85). Unset ⇒ classic-bundle, runs
  /// everywhere. The car fact it's checked against is now the MEASURED
  /// Chromium major (see `webview_capability.dart`), not a generation
  /// proxy — Di5.0 trims ship Chromium 95 and DO satisfy this.
  final bool? modernWebview;

  /// Minimum host bridge protocol version (semver-ish). Compared
  /// numerically; absent/unparseable host version fails closed.
  final String? minBridge;

  /// Lenient. Returns null when the catalog row has no `requires`
  /// block (the common "runs anywhere" case).
  static MiniAppRequires? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    List<String>? strList(Object? v) {
      if (v is! List) return null;
      final out = <String>[
        for (final e in v)
          if (e is String && e.trim().isNotEmpty) e,
      ];
      return out.isEmpty ? null : out;
    }

    final schemaRaw = m['schema'];
    return MiniAppRequires(
      schema: schemaRaw is num ? schemaRaw.toInt() : kRequiresSchema,
      dilink: strList(m['dilink']),
      vehicleCapabilities: strList(m['vehicleCapabilities']),
      modernWebview: m['modernWebview'] is bool
          ? m['modernWebview'] as bool
          : null,
      minBridge:
          (m['minBridge'] is String &&
              (m['minBridge'] as String).trim().isNotEmpty)
          ? m['minBridge'] as String
          : null,
    );
  }
}

/// The car/host facts the gate runs against. Built from the active
/// `CarProfile` + resolved DiLink. Mirror of the SDK `CompatTarget`.
class CompatTarget {
  const CompatTarget({
    required this.dilinkFamily,
    this.vehicleCapabilityBits,
    this.vehicleCapabilities,
    this.bridgeVersion,
    this.modernWebview,
  });

  /// Resolved DiLink generation: `'di5.0'`, `'di5.1'`, or `'unknown'`
  /// (a valid value — fails any explicit dilink/cluster requirement).
  final String dilinkFamily;

  /// Packed capability bitmask (preferred; hot path). Wins over
  /// [vehicleCapabilities] when both are present.
  final int? vehicleCapabilityBits;

  /// Readable capability list. Used only when bits are absent.
  final List<String>? vehicleCapabilities;

  /// Host bridge protocol version. Absent ⇒ a `minBridge`
  /// requirement fails closed.
  final String? bridgeVersion;

  /// Whether the car's WebView is modern (ES-module capable — measured
  /// Chromium ≥ 85; see `webview_capability.dart`). Absent ⇒ a
  /// `modernWebview` requirement fails closed (assume old).
  final bool? modernWebview;
}

/// Closed reason set — stable identifiers so the UI maps each to a
/// localized "why this app won't open" string without parsing text.
/// Same five codes as the SDK `COMPAT_REASON_CODES`.
enum CompatReasonCode {
  unsupportedRequiresSchema,
  dilinkUnsupported,
  missingVehicleCapabilities,
  webviewTooOld,
  bridgeTooOld,
}

class CompatReason {
  const CompatReason(this.code, this.detail);

  final CompatReasonCode code;

  /// English, for logs + dev tooling. Map [code] to a localized
  /// string for end-user display.
  final String detail;
}

class CompatResult {
  const CompatResult(this.ok, this.reasons);

  /// `true` ⇒ the app may be launched on this car.
  final bool ok;

  /// Empty when [ok]. One entry per failed rule (an app can fail
  /// several gates at once — surface them all).
  final List<CompatReason> reasons;
}

/// Numeric semver-ish compare, mirror of the SDK `semverishGte`.
/// Splits on `.`, compares the leading integer of each segment
/// (`2.0.0` < `2.1.0`, `2.0` == `2.0.0`). Non-numeric/empty input or
/// absent `have` ⇒ `null` = "cannot prove ≥" = fail closed.
bool? _semverishGte(String? have, String need) {
  if (have == null) return null;
  List<int>? parse(String v) {
    final parts = v.trim().split('.');
    if (parts.isEmpty) return null;
    final nums = <int>[];
    for (final s in parts) {
      final n = int.tryParse(s.trim());
      if (n == null) return null;
      nums.add(n);
    }
    return nums;
  }

  final a = parse(have);
  final b = parse(need);
  if (a == null || b == null) return null;
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return true;
}

/// One rule: `(requirements, target) → failure | null`. Appended to
/// [_rules]; nothing else changes (open/closed — callers never branch
/// on requirement kind). Order is identical to the SDK `RULES`.
typedef _CompatRule =
    CompatReason? Function(MiniAppRequires req, CompatTarget target);

final List<_CompatRule> _rules = <_CompatRule>[
  // 1. DiLink generation allow-list.
  (req, target) {
    final dilink = req.dilink;
    if (dilink == null) return null;
    if (dilink.contains(target.dilinkFamily)) return null;
    return CompatReason(
      CompatReasonCode.dilinkUnsupported,
      'app requires DiLink ${dilink.join('|')}; '
      'car is ${target.dilinkFamily}',
    );
  },

  // 2. Vehicle-hardware capability subset (branchless bitmask AND).
  (req, target) {
    final caps = req.vehicleCapabilities;
    if (caps == null) return null;
    final requiredBits = bitsFromCapabilities(caps);
    final targetBits =
        target.vehicleCapabilityBits ??
        bitsFromCapabilities(target.vehicleCapabilities ?? const <String>[]);
    if (hasAllCapabilities(targetBits, requiredBits)) return null;
    final missing = capabilitiesFromBits(requiredBits & ~targetBits);
    return CompatReason(
      CompatReasonCode.missingVehicleCapabilities,
      'car is missing required capabilities: ${missing.join(', ')}',
    );
  },

  // 3. Modern WebView (Chrome 100+). Absent target fact ⇒ assume old.
  (req, target) {
    if (req.modernWebview != true) return null;
    if (target.modernWebview == true) return null;
    return CompatReason(
      CompatReasonCode.webviewTooOld,
      target.modernWebview == false
          ? 'app needs a modern WebView; this trim ships the frozen '
                'Di5.0 WebView'
          : 'app needs a modern WebView; host did not report WebView '
                'age (fail closed)',
    );
  },

  // 4. Minimum host bridge protocol version.
  (req, target) {
    final need = req.minBridge;
    if (need == null) return null;
    final gte = _semverishGte(target.bridgeVersion, need);
    if (gte == true) return null;
    return CompatReason(
      CompatReasonCode.bridgeTooOld,
      gte == null
          ? 'app requires bridge ≥ $need; host bridge version unknown '
                '(fail closed)'
          : 'app requires bridge ≥ $need; host bridge is '
                '${target.bridgeVersion}',
    );
  },
];

/// Evaluate whether [requires] may run on [target]. Pure. Returns
/// early for the common "no requirements" case; otherwise runs every
/// rule so the caller sees every failed gate at once. `privileged` is
/// intentionally NOT considered here (distribution ACL, orthogonal).
CompatResult evaluateCompatibility(
  MiniAppRequires? requires,
  CompatTarget target,
) {
  final req = requires;
  if (req == null) return const CompatResult(true, <CompatReason>[]);

  // Forward-compat fail-closed: a newer schema carries at least one
  // hard gate this build can't evaluate.
  if (req.schema > kRequiresSchema) {
    return CompatResult(false, <CompatReason>[
      CompatReason(
        CompatReasonCode.unsupportedRequiresSchema,
        'manifest requires.schema=${req.schema} > supported '
        '$kRequiresSchema; update the host to evaluate this app',
      ),
    ]);
  }

  final reasons = <CompatReason>[];
  for (final rule in _rules) {
    final r = rule(req, target);
    if (r != null) reasons.add(r);
  }
  return CompatResult(reasons.isEmpty, reasons);
}

/// Boolean convenience for hot paths / conditionals.
bool isCompatible(MiniAppRequires? requires, CompatTarget target) =>
    evaluateCompatibility(requires, target).ok;
