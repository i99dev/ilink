// ignore_for_file: constant_identifier_names

/// DiLink firmware-version adapter — pinpoints the version-specific
/// behaviours that differ between BYD framework generations so the
/// rest of `BydClient` doesn't have to branch on them.
///
/// **Why a per-version adapter** — empirically observed differences
/// between DiLink 5.0, 5.1, and 8.x:
///
/// | Concern | DiLink 5.0 | DiLink 5.1 | DiLink 8.x |
/// |---------|-----------|-----------|-----------|
/// | Push registration | both shell-UID and Application context dispatch | Application context only (shell UID receives no `onPostEvent`) | confirmed-pending — Leopard 8 ROM check |
/// | Encrypted asset bundle | `assets/byd/dilink_5_0/car_table.pb.enc` | `assets/byd/dilink_5_1/car_table.pb.enc` (default) | `assets/byd/dilink_8_x/car_table.pb.enc` |
/// | Cluster pixel signing gate | open | open | signature-locked (see memory: leopard8 cluster signature gate) |
/// | `BYDAutoFeatureIds` integer assignments | some renumbered | stable from 5.1 onward | stable |
///
/// The adapter holds those answers as data so `BydClient` constructs
/// once and the choice is final-field for the lifetime of the app.
/// Hot-path dispatch hits zero conditionals — boot-time selection
/// only.
///
/// **Adding a new DiLink version:**
///
/// 1. Add an enum entry to [DilinkVersion].
/// 2. Add a concrete adapter (`byd_dilink_<version>.dart`) that
///    extends [BydDilinkAdapter].
/// 3. Wire detection in [BydDilinkAdapter.detect].
/// 4. Optionally ship a `.secrets/car_table/parts/<version>/`
///    textproto bundle if the action table diverges. The shared
///    bundle stays the fallback when no version-specific one is
///    present.
/// 5. Add a readiness test case under
///    `test/sdk/brands/byd/byd_readiness_test.dart`.
library;

/// Wire string for a detected DiLink version. Stable across the
/// codebase — used as part of [ProfileKey.firmwareVersion] and as
/// the asset-bundle subdirectory under
/// `assets/byd/<DilinkVersion.wire>/`.
// Enum values use snake_case to match the wire/asset-path spelling
// (`dilink_5_0`, `dilink_5_1`, `dilink_8_x`) — load-bearing, not
// stylistic, so `constant_identifier_names` is suppressed for the
// whole file.
enum DilinkVersion {
  /// First generation we support — Han / Tang on shipping ROMs
  /// before mid-2024.
  dilink_5_0,

  /// Default for everything shipped 2024H2 onward — Han L4, Tang L4,
  /// Leopard 5/8/9. Push dispatch is Application-context only.
  dilink_5_1,

  /// Leopard 8 / Yangwang ROMs with the signature-locked cluster
  /// pixel path. Mostly behaves like 5.1 plus extra signing gates.
  dilink_8_x,

  /// Detection failed — no framework class reachable, or the version
  /// reflection returned something we don't recognise. Conservative:
  /// behave like 5.1 for safety (most permissive).
  unknown;

  String get wire => switch (this) {
    DilinkVersion.dilink_5_0 => 'dilink_5_0',
    DilinkVersion.dilink_5_1 => 'dilink_5_1',
    DilinkVersion.dilink_8_x => 'dilink_8_x',
    DilinkVersion.unknown => 'unknown',
  };

  static DilinkVersion fromWire(String? s) => switch (s) {
    'dilink_5_0' => DilinkVersion.dilink_5_0,
    'dilink_5_1' => DilinkVersion.dilink_5_1,
    'dilink_8_x' => DilinkVersion.dilink_8_x,
    _ => DilinkVersion.unknown,
  };
}

/// Per-DiLink-version policy interface. One concrete adapter per
/// [DilinkVersion] entry. `BydClient` reads exactly the properties
/// it needs from the adapter; the rest of the brand code is
/// version-agnostic.
abstract class BydDilinkAdapter {
  const BydDilinkAdapter();

  /// Which framework version this adapter targets. Stable.
  DilinkVersion get version;

  /// Subdirectory name under `assets/byd/` for the version-specific
  /// encrypted action table. `null` to fall back to the shared
  /// `assets/car_table.pb.enc` (today's default).
  String? get assetBundleDir;

  /// True when the framework dispatches `AbsBYDAutoDevice.onPostEvent`
  /// ONLY to instances constructed under an `Application` context —
  /// i.e. the shell-UID daemon will not receive push frames. Empirical
  /// observation on DiLink 5.1 hardware (May 2026). Drives the
  /// in-app vs daemon push wiring decision.
  bool get pushRequiresAppContext;

  /// True when the cluster pixel write path is signature-gated by the
  /// framework (Leopard 8 / Yangwang ROMs). Drives whether we attempt
  /// the cluster-pixel write at all or skip straight to the alternate
  /// route.
  bool get clusterPixelSignatureGated;

  /// Detect the version at boot. Today returns 5.1 (the empirically
  /// dominant ROM); replace with a real reflection probe when 5.0 /
  /// 8.x detection is wired through Kotlin. Stays synchronous —
  /// the choice should be deterministic from a `Class.forName`-style
  /// probe, not a runtime IO call.
  static BydDilinkAdapter detect({DilinkVersion? force}) {
    final v = force ?? _probeFromFramework();
    return _byVersion[v]!;
  }

  /// Test factory. Pin a version for unit tests without going through
  /// the framework probe. Used by
  /// `test/sdk/brands/byd/byd_readiness_test.dart`.
  static BydDilinkAdapter forTesting(DilinkVersion v) => _byVersion[v]!;
}

DilinkVersion _probeFromFramework() {
  // TODO(detection): wire the Kotlin-side `Class.forName(...).getField(...)`
  //   probe that distinguishes 5.0 / 5.1 / 8.x by which `BYDAutoFeatureIds`
  //   constants exist. Returning 5.1 as default matches the current shipped
  //   ROM on every dev car; mis-detection falls through to the most
  //   permissive policy, never to a stricter one.
  return DilinkVersion.dilink_5_1;
}

// Initialised at the bottom of this file once concrete adapters are
// declared. The map is the single source of truth — `BydDilinkAdapter.detect`
// + `forTesting` both go through it.
late final Map<DilinkVersion, BydDilinkAdapter> _byVersion;

/// Internal registration hook called by the concrete adapter file
/// imports. Keeps the registration explicit rather than relying on
/// implicit type metadata which Dart doesn't expose for switch
/// completeness.
void registerBydDilinkAdapters(Map<DilinkVersion, BydDilinkAdapter> map) {
  _byVersion = Map.unmodifiable(map);
}
