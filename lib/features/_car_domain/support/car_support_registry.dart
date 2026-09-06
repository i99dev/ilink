/// Static lookup table mapping `(HuVendor, vehicle variant)` →
/// [CarSupportProfile]. Source-of-truth for which combinations
/// ilink supports at which [IntegrationTier].
///
/// **Resolution order** (first hit wins):
///   1. Exact `(huVendor, variant)` match — e.g. `(byd, l8)`.
///   2. Vendor-wildcard `(huVendor, '')` — covers "any car on this
///      HU" so we get a baseline tier for vendors we recognise even
///      on a model we haven't profiled (e.g. a brand-new BYD release
///      before the variant detector knows it).
///   3. [CarSupportProfile.unknownVehicle] sentinel — fails closed.
///
/// **Seed data:** the initial entries cover what ilink has
/// reverse-engineered today (Leopard 5 / 5L / 5U / 7 / 8 on BYD
/// DiLink) plus stock-tier coverage for the seven other HU vendors
/// Dudu Launcher Pro's resource strings reference (Yuanfeng, Desay,
/// Liangshan, Shinco, HK, acloud, NWD). Stock-tier entries lock in
/// the read-side surface (telemetry, voice, MQTT, launcher mode)
/// without committing the actuator path until each vendor's quirks
/// are properly documented.
///
/// Adding a new entry:
///   1. Append to [_entries] with the right tier.
///   2. Add the variant id to `lib/sdk/brands/byd/identity/byd_model_detector.dart`'s
///      `_resolveModel` so detection can produce it. Keyed on the
///      `(carType, vehicleId)` pair from `BydCarInfoBinder` (the
///      BYD `ICarInfoManager` SDK with a `persist.sys.*` sysprop
///      fallback).
///   3. If the entry has known issues, populate [CarSupportProfile.quirks]
///      with the action ids from `lib/features/_car_domain/registry/`.
library;

import 'car_support_profile.dart';
import 'hu_vendor.dart';
import 'integration_tier.dart';
import 'known_quirk.dart';

class CarSupportRegistry {
  const CarSupportRegistry();

  /// Resolve a profile for the detected pair. Always returns a usable
  /// profile — falls back to vendor-wildcard, then to
  /// [CarSupportProfile.unknownVehicle].
  CarSupportProfile resolve({
    required HuVendor huVendor,
    required String variant,
  }) {
    // Exact (vendor, variant) match.
    for (final p in _entries) {
      if (p.huVendor == huVendor && p.variant == variant) return p;
    }
    // Vendor wildcard ("any car on this HU").
    for (final p in _entries) {
      if (p.huVendor == huVendor && p.variant.isEmpty) return p;
    }
    // No coverage at all.
    return CarSupportProfile.unknownVehicle;
  }

  /// Every profile in declaration order. Public for the Diagnostics
  /// "supported cars" surface so the user can see what we've shipped
  /// for; also used by the registry contract test to assert each
  /// profile is reachable.
  List<CarSupportProfile> all() => List.unmodifiable(_entries);

  // ──────────────────────────────────────────────────────────────────
  // Seed entries — order matters per the resolution rules above:
  // exact-variant rows BEFORE the vendor-wildcard row for that vendor,
  // otherwise the wildcard would shadow the more-specific match.
  // ──────────────────────────────────────────────────────────────────

  static const _entries = <CarSupportProfile>[
    // ─ BYD DiLink — full integration. The reverse-engineered
    // Leopard line is what ilink was originally built for, plus
    // HAN L which shares enough of the actuator surface that the
    // existing CarCommandRouter handles it without per-model
    // overrides.
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l8',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 8',
    ),
    // Leopard 8 drone-kit ROM (XDJA FSE-on-2 display layout). Same
    // vehicle as l8 — full integration; the variant id differs only so
    // it can carry its own DisplayProfile + DiShare FSE transport.
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l8_dk',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 8',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l5',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 5',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l5_nav',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 5 Navigator',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l5l',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 5 Lidar',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l5u',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 5 Ultra',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'l7',
      tier: IntegrationTier.full,
      displayName: 'BYD Leopard 7',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'han_l',
      tier: IntegrationTier.full,
      displayName: 'BYD HAN L',
    ),
    // Ocean-series Di5.0 / BYD-container — full integration (same
    // BYDAutoManager + DiShare surface as the Leopard line). Sealion 06
    // EV (BEV); the DM-i variant falls to the BYD wildcard until it needs
    // its own row.
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'sealion6_ev',
      tier: IntegrationTier.full,
      displayName: 'BYD Sealion 06 EV',
    ),

    // ─ BYD DiLink — also `full`. Car-control on BYD DiLink is
    // UNIVERSAL: the same `BYDAutoManager` actuator surface
    // (doors/windows/climate/seats/fragrance/lights) + the same
    // DiShare cluster path on every trim — it does NOT vary by model,
    // so the tier is not split per-variant. These rows exist only to
    // carry the marketing displayName + per-trim quirks; the tier is
    // uniformly `full`. (Earlier these were `stock` on per-trim
    // caution — a stale mis-tier: e.g. Song PLUS's CarProfile already
    // mirrors the L5 archetype exactly.) A mis-fire on a trim whose
    // ROM differs degrades to an honest "didn't actuate" via the #127
    // launch-outcome decoder, never a dangerous action. Quirks lifted
    // from Dudu Launcher Pro's resource strings (validated 2026-05-10).
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'song_plus',
      tier: IntegrationTier.full,
      displayName: 'BYD Song PLUS',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'song_plus_sd',
      tier: IntegrationTier.full,
      displayName: 'BYD Song PLUS Smart Drive',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'song_pro',
      tier: IntegrationTier.full,
      displayName: 'BYD Song Pro',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'qin_l',
      tier: IntegrationTier.full,
      displayName: 'BYD Qin L',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: 'qin_plus',
      tier: IntegrationTier.full,
      displayName: 'BYD Qin Plus',
    ),
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: '5f',
      tier: IntegrationTier.full,
      displayName: 'BYD F-series',
    ),

    // ─ BYD vendor wildcard. Any other DiLink-detected BYD car gets
    // `full` too — same universal BYD control plane (see above). This
    // makes the app "ready for any new BYD car" out of the box rather
    // than dimming control until a per-variant row is hand-added;
    // unrecognised ROMs that genuinely differ self-correct via the
    // daemon authority + #127 decoder. MUST stay at the end of the BYD
    // block (after every exact-variant row) per the resolution rules.
    CarSupportProfile(
      huVendor: HuVendor.byd,
      variant: '',
      tier: IntegrationTier.full,
      displayName: 'BYD vehicle (other)',
    ),

    // ─ Yuanfeng aftermarket HU (Baidu OS fork). Common on Han EV
    // / Han DM aftermarket installs. Stock-tier today; the actuator
    // surface needs separate RE because Yuanfeng's daemon
    // interface differs from BYD's.
    CarSupportProfile(
      huVendor: HuVendor.yuanfeng,
      variant: 'han_l',
      tier: IntegrationTier.stock,
      displayName: 'Han EV on Yuanfeng',
      quirks: [
        KnownQuirk(
          actionId: 'window.fl.close',
          severity: QuirkSeverity.warning,
          message:
              'Some Han EV trims may not fully close this window. Lock the '
              'car and wait 5 min for the auto-finish to take over.',
        ),
        KnownQuirk(
          actionId: 'window.fr.close',
          severity: QuirkSeverity.warning,
          message:
              'Some Han EV trims may not fully close this window. Lock the '
              'car and wait 5 min for the auto-finish to take over.',
        ),
      ],
    ),
    CarSupportProfile(
      huVendor: HuVendor.yuanfeng,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'Yuanfeng-hosted vehicle',
    ),

    // ─ Desay SV. Common on Tang and some Yuan trims. Stock-tier;
    // the daemon gate works but actuator routing needs separate RE.
    CarSupportProfile(
      huVendor: HuVendor.desay,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'Desay SV-hosted vehicle',
    ),

    // ─ Liangshan / Far Frontier aftermarket. Premium add-on; some
    // surfaces gated behind their licensed SDK we don't carry.
    // Stock-tier baseline.
    CarSupportProfile(
      huVendor: HuVendor.liangshan,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'Liangshan-hosted vehicle',
    ),

    // ─ Shinco / HK / acloud / NWD aftermarket chassis. The
    // launcher manifest aliases pick these up for HOME registration
    // (commit e7b64a4); stock-tier here so the rest of the app
    // does the same.
    CarSupportProfile(
      huVendor: HuVendor.shinco,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'Shinco-hosted vehicle',
    ),
    CarSupportProfile(
      huVendor: HuVendor.hk,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'HK-hosted vehicle',
    ),
    CarSupportProfile(
      huVendor: HuVendor.acloud,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'acloud-hosted vehicle',
    ),
    CarSupportProfile(
      huVendor: HuVendor.nwd,
      variant: '',
      tier: IntegrationTier.stock,
      displayName: 'NWD-hosted vehicle',
    ),
  ];
}
