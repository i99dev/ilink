/// Coarse-to-fine BYD model identifier. Read once at boot through
/// the `ilink/model_detector` platform channel; cached for the
/// session via [modelDetectorProvider]; consumed by:
///
///   * `MiniAppDispatcher` on the Kotlin side via the `model.id`
///     ContentProvider value (see `MiniAppTableSource.opRouteByToken`
///     and the `model_match` field on `OpRoute`).
///   * `SentryContextSync` — surfaces `car.variant`, `car.brand`,
///     `car.bydCarType`, `car.vehicleId` and the friendly name as
///     scope tags on every event so triage can filter by trim
///     without per-call-site changes.
///
/// ## How identity is resolved (2026-05-10+)
///
/// The detector binds to BYD's own `ICarInfoManager` via reflection
/// (Kotlin-side [BydCarInfoBinder]). The SDK returns the canonical
/// car-type string (one of 21 values: HAN, TANG, SONG, QIN, XIA,
/// SEAL, SEALION, DOLPHIN, N7, N8, N9, D9, Z9, FCBSF, FCBSQ,
/// FCBURE, R1, R2, R3, R4, unknown), the brand family (DYNASTY /
/// OCEAN / DENZA / F / R / UNKNOWN), a granular integer
/// `vehicleId`, the VIN, the body class, and the powertrain code.
/// All in one binder call.
///
/// This replaced the previous fan-out of 10+ system-property reads
/// + outsw / default_name / system-model heuristics. The new path:
///
///   * Authoritative — same source BYD's stock apps consume.
///   * Future-proof — new BYD models added to the framework appear
///     here without us shipping `_resolveByOutsw` rows.
///   * Coverage 21 → 8 (jump in supported model count, including
///     all Dynasty / Ocean / Denza / Yangwang lines that were
///     previously `unknown`).
///
/// ## Identifier ladder, finest to coarsest
///
///   1. Variant — the trim-precise key used by `model_match`
///      selectors (`l8`, `tang`, `denza_n7`, `yangwang_r1`, …).
///      Resolved from the SDK's (carType, vehicleId) pair.
///   2. DiLink family (`di5.1`, `di5.0`). Use when an op is the
///      same across every trim of a generation but differs across
///      generations. Read from the single retained sysprop
///      (`ro.vehicle.type`) since the BYD SDK doesn't expose
///      DiLink generation directly.
///   3. `unknown` — the BYD SDK is unavailable (non-BYD HU,
///      stripped framework, or pre-DiLink-5.0). Dispatcher falls
///      through to routes with no `model_match`.
///
/// ## Adding a new trim
///
/// Two ways:
///
///   * The trim already exists in BYD's framework — variant is
///     derived from `(carType, vehicleId)` in [_resolveModel]. Add
///     a row when you observe a new vehicleId for an existing
///     carType (e.g. a new FangChengBao SKU sharing `FCBSF`).
///   * The trim has its own carType — already covered. The
///     variant id falls out of the [_resolveModel] switch
///     mechanically.
///
/// No textproto change needed unless you also want trim-specific
/// `model_match` rules.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _channel = MethodChannel('ilink/model_detector');

/// Snapshot of "which BYD am I running on?" Read once at boot,
/// cached for the rest of the session. Exposed both as a typed
/// object (for in-process consumers like sentry_context_sync) and
/// as a single `id` string (for the Kotlin dispatcher's
/// `model_match` selector).
@immutable
class ModelId {
  const ModelId({
    required this.variant,
    required this.dilinkFamily,
    required this.bydCarType,
    required this.brand,
    required this.bodyType,
    required this.vehicleId,
    required this.vin,
    required this.powerType,
    required this.driverSeat,
    this.friendlyName,
    this.make,
    this.headUnit,
    this.region,
  });

  /// Friendliest tag — what `model_match` should target for
  /// trim-specific overrides. `l8` / `l5` / `l5l` / `l5u` / `l7` /
  /// `5f` / `han_l` / `song_plus` / `tang` / `qin` / `xia` /
  /// `seal` / `sealion` / `dolphin` / `denza_n7..z9` /
  /// `yangwang_r1..r4` / `fcbsq` / `fcbure` today. Null for trims
  /// the resolver hasn't profiled yet.
  final String? variant;

  /// `di5.1` / `di5.0` / `unknown`. Use when an op differs across
  /// DiLink generations but not within a generation. Resolved from
  /// `ro.vehicle.type` — the only sysprop kept post-2026-05-10
  /// because BYD's SDK doesn't expose generation directly.
  final String dilinkFamily;

  /// Canonical BYD car-type string from `ICarInfoManager.getCarType()`.
  /// One of: HAN / TANG / SONG / QIN / XIA / SEAL / SEALION /
  /// DOLPHIN / N7 / N8 / N9 / D9 / Z9 / FCBSF / FCBSQ / FCBURE /
  /// R1 / R2 / R3 / R4 / null. Surfaced in Sentry for triage —
  /// finer-grained than `variant` for unprofiled trims because the
  /// SDK still returns the family code even when our resolver
  /// hasn't mapped a specific `vehicleId` yet.
  final String? bydCarType;

  /// BYD brand family from `getBrand()` — DYNASTY / OCEAN / DENZA
  /// / F (FangChengBao) / R (Yangwang) / UNKNOWN. Coarser than
  /// [bydCarType]; useful for brand-level UI hints.
  final String? brand;

  /// Body class from `getVehicleType()` — CAR / SUV / MPV / TRUCK
  /// / etc. Distinct from [bydCarType]; both come from the same
  /// manager.
  final String? bodyType;

  /// Granular int identifier from `getVehicleId()`. Distinguishes
  /// trims that share a [bydCarType] — e.g. all Leopard 5 sub-trims
  /// share `FCBSF` but have distinct vehicleIds (L8 = 31). -1 when
  /// unset.
  final int vehicleId;

  /// VIN from `getSerialNumber()`. Surfaced for triage; not used
  /// by routing.
  final String? vin;

  /// Powertrain encoding from `getPowerType()` — int per BYD's
  /// internal taxonomy (EV / PHEV / ICE). -1 when unset.
  final int powerType;

  /// Driver-seat side from `getDriverSeat()`. Reserved for future
  /// LHD/RHD UX — captured at boot. -1 when unset.
  final int driverSeat;

  /// Human-readable trim name resolved alongside [variant]. Null
  /// when the variant fell through to the dilinkFamily / unknown
  /// fallback.
  final String? friendlyName;

  /// Coarse vendor from Android `Build.MANUFACTURER` ("BYD" /
  /// "GeneralMotors" / …). Surfaced because future non-BYD support
  /// will branch on it; today every car is BYD so it's effectively
  /// constant. Folded into [ModelId] (rather than living in a
  /// separate provider) so the sign-in fingerprint has ONE source
  /// of truth — the legacy `CarIdentity.localOnly()` sysprop fan-out
  /// is being retired.
  final String? make;

  /// Head-unit firmware family marker from `ro.product.model` —
  /// "DiLink5.1" on the L8 we audit against. Distinct concern from
  /// vehicle id (firmware != car) but tagged on installs for
  /// support triage. Same retirement rationale as [make].
  final String? headUnit;

  /// Two-letter ISO country derived from
  /// `gsm.sim.operator.iso-country` ("ae", "sa", "cn", …). Used by
  /// the backend to localise the Telegram bot's first reply on
  /// pair. Most reliable on L8; some trims don't populate the
  /// `persist.sys.byd.region` keys reliably so we read the SIM
  /// directly. Same retirement rationale as [make].
  final String? region;

  /// The single string the dispatcher's `model_match` selector
  /// compares against. Picks the finest available level so a
  /// textproto entry with `model_match: ["tang"]` wins over one
  /// with `model_match: ["di5.1"]` for a Tang head unit.
  String get id => variant ?? dilinkFamily;

  /// Test/dev fixture. Use only from tests.
  static const ModelId unknown = ModelId(
    variant: null,
    dilinkFamily: 'unknown',
    bydCarType: null,
    brand: null,
    bodyType: null,
    vehicleId: -1,
    vin: null,
    powerType: -1,
    driverSeat: -1,
    make: null,
    headUnit: null,
    region: null,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'variant': variant,
    'dilinkFamily': dilinkFamily,
    'bydCarType': bydCarType,
    'brand': brand,
    'bodyType': bodyType,
    'vehicleId': vehicleId,
    'vin': vin,
    'powerType': powerType,
    'driverSeat': driverSeat,
    'friendlyName': friendlyName,
    'make': make,
    'headUnit': headUnit,
    'region': region,
    'id': id,
  };
}

/// One-shot detector. Calls `getCarInfo` on the platform channel
/// (Kotlin reflects into BYD's `ICarInfoManager`), classifies into
/// a [ModelId], caches forever. Falls back to [ModelId.unknown] on
/// non-Android platforms (web, dev macOS) so dev tools that don't
/// run on a head unit still load.
class ModelDetector {
  ModelDetector._();

  static ModelId? _cached;

  /// Read once, cache forever. Subsequent calls are O(1). After the
  /// first resolve, pushes the resulting id chain to the Kotlin
  /// dispatcher so the `model_match` selector has something to
  /// match against.
  static Future<ModelId> detect() async {
    if (_cached != null) return _cached!;
    if (!Platform.isAndroid) {
      return _cached = ModelId.unknown;
    }
    final raw = await _readCarInfo();
    final autoDetected = _classify(raw);
    final override = await _readOverride();
    final model = _applyOverride(autoDetected, override);
    _cached = model;
    // Push the finest-to-coarsest match chain to the Kotlin
    // dispatcher. Sending both `variant` and `dilinkFamily` keeps
    // existing textproto entries that target the family code
    // working even after the per-trim variant resolves more
    // precisely. Fire-and-forget — failures here just mean the
    // Kotlin side stays on its default `unknown` which is already
    // the safest behavior.
    try {
      final chain = <String>[
        if (model.variant != null) model.variant!,
        if (model.dilinkFamily != 'unknown') model.dilinkFamily,
      ];
      await _channel.invokeMethod<void>('setModelId', {'ids': chain});
    } catch (_) {
      // ignore
    }
    return model;
  }

  /// Currently-set user profile override, or null when auto-detect
  /// is in effect. Reads through the channel — survives app
  /// restarts via the Kotlin SharedPreferences.
  static Future<String?> profileOverride() async {
    if (!Platform.isAndroid) return null;
    return _readOverride();
  }

  /// Force-pick a vehicle profile variant. Pass null (or an empty
  /// string) to clear and resume auto-detect. Persisted across
  /// reboots. Invalidates the in-process cache and re-runs
  /// [detect], so the returned ModelId reflects the override
  /// immediately. UI can rebuild on this future.
  ///
  /// Auto-detected `dilinkFamily` and the BYD-SDK-sourced fields
  /// (`bydCarType`, `brand`, `vehicleId`, `vin`, `powerType`,
  /// `bodyType`) are preserved — the override only replaces the
  /// resolved `variant`. Setting `tang` on a Han ROM still reports
  /// `bydCarType="HAN"`; the dispatcher's chain becomes
  /// `["tang", "di5.1"]` so trim-targeted routes win but the
  /// actual ROM identity isn't lied about downstream.
  static Future<ModelId> setProfileOverride(String? variant) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>(
          'setProfileOverride',
          <String, Object?>{'variant': variant},
        );
      } catch (_) {
        // ignore
      }
    }
    _cached = null;
    return detect();
  }

  /// Wraps the channel-side `getCarInfo` call. Returns an empty map
  /// when the BYD SDK isn't bindable (non-BYD HU, stripped
  /// framework, test fake) so [_classify] cleanly resolves to
  /// [ModelId.unknown].
  static Future<Map<String, Object?>> _readCarInfo() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getCarInfo',
      );
      return result ?? const <String, Object?>{};
    } catch (_) {
      // Channel missing / SDK absent / RemoteException — keep boot
      // alive; classify falls through to unknown.
      return const <String, Object?>{};
    }
  }

  static Future<String?> _readOverride() async {
    try {
      return await _channel.invokeMethod<String?>('getProfileOverride');
    } catch (_) {
      return null;
    }
  }

  /// Apply [override] to [autoDetected]. Override takes priority
  /// over the auto-detected variant; everything else passes
  /// through unchanged. Empty / null override is a no-op.
  static ModelId _applyOverride(ModelId autoDetected, String? override) {
    if (override == null || override.isEmpty) return autoDetected;
    if (override == autoDetected.variant) return autoDetected;
    return ModelId(
      variant: override,
      dilinkFamily: autoDetected.dilinkFamily,
      bydCarType: autoDetected.bydCarType,
      brand: autoDetected.brand,
      bodyType: autoDetected.bodyType,
      vehicleId: autoDetected.vehicleId,
      vin: autoDetected.vin,
      powerType: autoDetected.powerType,
      driverSeat: autoDetected.driverSeat,
      friendlyName: _friendlyNameForVariant(override),
      // Override only replaces variant — make / headUnit / region
      // are ROM-derived and stay accurate even when the user
      // force-picks a different profile.
      make: autoDetected.make,
      headUnit: autoDetected.headUnit,
      region: autoDetected.region,
    );
  }

  /// Variant id → human-readable label. Mirrors the labels emitted
  /// by [_resolveModel]. Used by the override path so a manually
  /// picked profile carries the same friendly label as an
  /// auto-detected one.
  static String? _friendlyNameForVariant(String variant) =>
      _kFriendlyNames[variant];

  /// Test-only: install a synthetic ModelId without going through
  /// the platform channel. Cleared by [resetForTesting].
  @visibleForTesting
  static void debugSetCached(ModelId model) {
    _cached = model;
  }

  @visibleForTesting
  static void resetForTesting() {
    _cached = null;
  }

  /// Test seam over [_classify]. Pass the same map shape
  /// `getCarInfo` returns; get back a [ModelId]. Cheap, no I/O.
  @visibleForTesting
  static ModelId classifyForTest(Map<String, Object?> raw) => _classify(raw);

  /// Classification rules. Append-only on the variant side —
  /// adding a new trim is one row in [_resolveModel] (or
  /// [_kFriendlyNames] for label-only changes).
  static ModelId _classify(Map<String, Object?> raw) {
    // Treat the SDK sentinel `"unknown"` the same as missing —
    // downstream consumers (Sentry, profile resolver, mini-app
    // dispatcher) shouldn't see the literal sentinel polluting
    // the carType field.
    final carTypeRaw = (raw['carType'] as String?)?.trim();
    final carType =
        (carTypeRaw == null ||
            carTypeRaw.isEmpty ||
            carTypeRaw.toLowerCase() == 'unknown')
        ? null
        : carTypeRaw;
    final brand = (raw['brand'] as String?)?.trim();
    final bodyType = (raw['bodyType'] as String?)?.trim();
    final vehicleId = _parseInt(raw['vehicleId']);
    final vin = (raw['vin'] as String?)?.trim();
    final powerType = _parseInt(raw['powerType']);
    final driverSeat = _parseInt(raw['driverSeat']);
    final dilinkRaw = (raw['dilinkRaw'] as String?)?.trim();
    final defaultName = (raw['defaultName'] as String?)?.trim();

    final dilinkFamily = _resolveDilinkFamily(dilinkRaw);

    final resolved = _resolveModel(carType, vehicleId, defaultName, dilinkRaw);

    final make = (raw['make'] as String?)?.trim();
    final headUnit = (raw['headUnit'] as String?)?.trim();
    final region = (raw['region'] as String?)?.trim();

    return ModelId(
      variant: resolved?.$1,
      dilinkFamily: dilinkFamily,
      bydCarType: carType?.isNotEmpty == true ? carType : null,
      brand: brand?.isNotEmpty == true ? brand : null,
      bodyType: bodyType?.isNotEmpty == true ? bodyType : null,
      vehicleId: vehicleId,
      vin: vin?.isNotEmpty == true ? vin : null,
      powerType: powerType,
      driverSeat: driverSeat,
      friendlyName: resolved?.$2,
      make: make?.isNotEmpty == true ? make : null,
      headUnit: headUnit?.isNotEmpty == true ? headUnit : null,
      region: region?.isNotEmpty == true ? region : null,
    );
  }

  static int _parseInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? -1;
    return -1;
  }

  static String _resolveDilinkFamily(String? raw) {
    if (raw == null) return 'unknown';
    // Two `ro.vehicle.type` formats seen in the field for the same
    // generation:
    //   * `Di5.1_*` / `Di5.0_*` — internal form (e.g. L8 "Di5.1_5.0UI").
    //   * `DiLink150_*` / `DiLink100_*` — public marketing-number form
    //     (150 = DiLink 5.1, 100 = DiLink 5.0). Live on the Leopard 7
    //     (`ro.vehicle.type="DiLink150_7.0UI"`, 2026-06-11). Without
    //     this branch a DiLink150 ROM whose variant doesn't resolve
    //     falls to 'unknown' → permissive GENERIC_PROFILE instead of
    //     the generation-correct, cluster-safe GENERIC_DI51.
    if (raw.contains('Di5.1') || raw.contains('DiLink150')) return 'di5.1';
    if (raw.contains('Di5.0') || raw.contains('DiLink100')) return 'di5.0';
    return 'unknown';
  }

  /// `(carType, vehicleId)` → `(variantId, friendlyName)`.
  ///
  /// Resolution rules (first match wins):
  ///
  ///   1. **FangChengBao trims** — `FCBSF` / `FCBSQ` / `FCBURE`
  ///      share a carType; the `vehicleId` integer
  ///      (`persist.sys.vehicle_40d_code`) pins the actual trim
  ///      (L5=153, L8=155, …). Live-validated against a Leopard 8
  ///      dev unit (`carType=FCBSQ`, `vehicleId=155`) on
  ///      2026-05-10.
  ///   2. **vehicleId-only** entries — for trims where BYD doesn't
  ///      populate `persist.sys.model_variant.model` (or it
  ///      reports `unknown`). The integer code40d alone is
  ///      sufficient — e.g. Song PLUS = 243 with no model-variant
  ///      token.
  ///   3. **carType-only** entries — every non-FCB model. The SDK
  ///      enum is the canonical key; vehicleId is informational.
  ///   4. **family-level fallback** — when the trim hasn't been
  ///      profiled yet (new vehicleId for a known carType), fall
  ///      through to a family-level variant (`fcbsf` / `fcbsq` /
  ///      `fcbure`). The Kotlin `CarProfileRegistry` routes these
  ///      to `GENERIC_PROFILE` until a per-trim profile lands.
  ///
  /// Adding a new trim:
  ///   * Known carType + new vehicleId in the FCB family: add a
  ///     `case` inside the relevant FCB branch.
  ///   * New carType: add a top-level case.
  ///   * code40d observed for an SDK-less trim (modelVariant
  ///     reports `unknown`): add a row in the vehicleId-only
  ///     section.
  static (String, String)? _resolveModel(
    String? carType,
    int vehicleId, [
    String? defaultName,
    String? dilinkRaw,
  ]) {
    // 7.0UI ROMs (e.g. "DiLink150_7.0UI") stopped populating code40d
    // (vehicle_40d_code=0) — which collides with the 5.0UI DJI-drone-kit unit
    // that also reports 0. Use the UI string to tell them apart below.
    final is7ui = (dilinkRaw ?? '').contains('7.0UI');
    // Di5.0 BYD-container generation (Di5.0_5.0UI) vs Di5.1/XDJA. Used to
    // gate FCBSF trims whose code40d is unset (0) onto the DiShare
    // profile so a future Di5.1 FCBSF with an unset code never grabs it.
    final isDi50 = (dilinkRaw ?? '').contains('Di5.0');
    // ── 1. FangChengBao — (carType, vehicleId) pair ──────────────
    if (carType != null) {
      switch (carType) {
        case 'FCBSQ':
          // FCBSQ is the FangChengBao Leopard 8 family (L8-only today).
          // Standard L8: code40d=155 → the canonical 5-surface
          // LEOPARD8_PROFILE (FSE on a standalone owner=null display 2,
          // cluster on display 5).
          if (vehicleId == 155) return ('l8', 'Leopard 8');
          // DJI-drone-kit unit: code40d=0 (sysprop unset) / framework
          // getVehicleId()=31 — live 2026-06-19 (adb 127.0.0.1:5999),
          // default_name 豹8, Di5.1_5.0UI, energytype=2. SAME vehicle but
          // a DIFFERENT XDJA display ROM (all secondaries XDJA-owned,
          // FSE on display 2, cluster split across 3+4, no display 5), so
          // it gets its own LEOPARD8_DRONEKIT_PROFILE — routing it to the
          // standard l8 would hide its real cluster (3/4) and lose the
          // passenger. The drone kit (com.byd.droneclient) is irrelevant;
          // it's the ROM's display layout that differs.
          if (vehicleId == 0 || vehicleId == 31) {
            // The NEW UI7 L8 (DiLink150_7.0UI) ALSO reports code40d=0, but it's a
            // STANDARD L8 (car.type=155), NOT the drone kit — routing it to the
            // drone-kit display map breaks cluster drag-drop. Only the 5.0UI unit
            // is the actual drone kit. Verified on-car 2026-06-28.
            if (is7ui) return ('l8', 'Leopard 8');
            return ('l8_dk', 'Leopard 8');
          }
          // Any other FCBSQ is still Leopard 8 — default to the standard
          // profile (conservative; not the drone-kit display map), never
          // the GENERIC_DI51 'fcbsq' stub.
          return ('l8', 'Leopard 8');
        case 'FCBSF':
          // L5: modelVariant=fcbsf + code40d=153 (per
          // CarProfileRegistry/Leopard5.kt).
          if (vehicleId == 153) return ('l5', 'Leopard 5');
          // L5 Ultra (Di5.1 / XDJA): code40d=304. Live-validated
          // 2026-06-11 on a real Leopard 5 Ultra (adb 127.0.0.1:5999):
          // model_variant=fcbsf, vehicle_40d_code=304, default_name
          // 豹5, ro.vehicle.type Di5.1_5.0UI, and the full 5-display
          // XDJA topology (cluster on display 5) that the existing
          // LEOPARD5_ULTRA_PROFILE (DI51_XDJA_CLUSTER) models. Without
          // this row a real Ultra fell to the permissive 'fcbsf'
          // family stub and never got the XDJA cluster profile. (If a
          // unit ever surfaces as the Lidar trim at this code40d it's a
          // one-word change to 'l5l' — l5l/l5u are behaviourally
          // identical XDJA-cluster profiles.)
          if (vehicleId == 304) return ('l5u', 'Leopard 5 Ultra');
          // L5 Navigator: code40d=0 (UNSET) on a Di5.0 BYD-container
          // PHEV. Live 2026-06-20 (adb 127.0.0.1:5999): model_variant
          // fcbsf, default_name 豹5, Di5.0_5.0UI, energytype=2. Behaviour
          // is identical to base L5 (DI50_BYD_DISHARE); it just exposes
          // no code40d (base L5 is 153, L5 Ultra 304). Gate on Di5.0 so
          // a future Di5.1 FCBSF with an unset code can't grab the
          // DiShare profile → LEOPARD5_NAVIGATOR_PROFILE.
          if (vehicleId == 0 && isDi50) {
            return ('l5_nav', 'Leopard 5 Navigator');
          }
          return ('fcbsf', 'FangChengBao FCBSF');
        case 'FCBURE':
          return ('fcbure', 'FangChengBao FCBURE');
      }
    }

    // ── 2. vehicleId-only — modelVariant is `unknown` or missing ─
    // BYD doesn't always populate `persist.sys.model_variant.model`
    // (Song PLUS reports it as "unknown" per Leopard5.kt comment).
    // The integer code40d alone is sufficient when known.
    switch (vehicleId) {
      case 201:
        // BYD Sealion 06 EV (海狮06EV, 2025) — Di5.0 / BYD container,
        // pure-EV. Live 2026-06-19 (adb 127.0.0.1:5999): default_name
        // 海狮06EV, Di5.0_5.0UI, code40d=201, model_variant=unknown
        // (carType null), energytype=1 → BEV. Same BYD-container topology
        // as the Sealion 6 DM-i; the only delta is powertrain → its own
        // SEALION6_EV_PROFILE (DI50_BYD_DISHARE + Powertrain.Ev). The
        // DM-i reports code40d=0 and resolves by the 海狮06DM nameplate;
        // this EV exposes the integer, so the vehicleId tier pins it.
        return ('sealion6_ev', 'BYD Sealion 06 EV');
      case 243:
        return ('song_plus', 'Song PLUS');
      case 330:
        // Song PLUS Smart Drive (BEV) — Di5.0 / BYD container. Live
        // 2026-06-12 (adb 127.0.0.1:5999): default_name 宋PLUS,
        // Di5.0_5.0UI, code40d=330 (base Song PLUS is 243; both expose
        // no model_variant token, so carType is null and we key on the
        // integer). energytype=1 → pure-EV → SONG_PLUS_SD_PROFILE
        // (DI50_BYD_DISHARE + Powertrain.Ev).
        return ('song_plus_sd', 'Song PLUS Smart Drive');
      case 282:
        // Leopard 7 (Ti7 / 钛7) — DiLink 5.1 / XDJA. Live-validated
        // 2026-06-11 on a real L7 (adb 127.0.0.1:5999): the sysprop
        // fallback reports `model_variant.model="qz"` → carType "QZ"
        // (NOT one of the FCB enum strings, so the tier-1 carType
        // switch above misses it) and `vehicle_40d_code=282`. The
        // integer code40d is the authoritative, path-independent key
        // — identical on the framework `getVehicleId()` and the
        // sysprop fallback — so resolve L7 here, mirroring Song PLUS.
        // Routes to LEOPARD7_PROFILE in the Kotlin registry.
        return ('l7', 'Leopard 7');
    }

    // ── 2.5 Nameplate disambiguation — for trims the integer/token
    // paths can't pin (model_variant=unknown AND code40d=0/unset), where
    // the only usable sysprop signal is persist.sys.byd.default_name.
    // Mirrors the L7 钛7 / L5 豹5 default_name precedent. Checked BEFORE
    // the coarse carType map so a precise sub-trim wins over a family stub
    // (e.g. carType SEALION -> the 'sealion' stub), but only on a positive
    // nameplate match — a non-matching name falls straight through.
    final byName = _resolveByDefaultName(defaultName);
    if (byName != null) return byName;

    // ── 3. Other carTypes — 1:1 mapping ─────────────────────────
    if (carType == null || carType.isEmpty) return null;
    switch (carType) {
      // FangChengBao — model_variant token "qz" = Ti7 / 钛7
      // (Leopard 7). Resolving L7 by carType ALONE means a unit that
      // reports an unset `vehicle_40d_code` (= 0) still detects, instead
      // of falling to the permissive GENERIC_DI51. Live 2026-06-12 on a
      // 2nd L7: same qz / DiLink150_7.0UI / 钛7 / outsw 34.1.35 as the
      // first, but code40d=0 + a different VIN. The code40d=282 path
      // (tier 2 above) still wins when the integer is populated.
      case 'QZ':
        return ('l7', 'Leopard 7');
      // Dynasty
      case 'HAN':
        return ('han', 'BYD Han');
      case 'QIN':
        return ('qin', 'BYD Qin');
      case 'SONG':
        return ('song', 'BYD Song');
      case 'TANG':
        return ('tang', 'BYD Tang');
      case 'XIA':
        return ('xia', 'BYD Xia');

      // Ocean
      case 'DOLPHIN':
        return ('dolphin', 'BYD Dolphin');
      case 'SEAL':
        return ('seal', 'BYD Seal');
      case 'SEALION':
        return ('sealion', 'BYD Sealion');

      // Denza
      case 'D9':
        return ('denza_d9', 'Denza D9');
      case 'N7':
        return ('denza_n7', 'Denza N7');
      case 'N8':
        return ('denza_n8', 'Denza N8');
      case 'N9':
        return ('denza_n9', 'Denza N9');
      case 'Z9':
        return ('denza_z9', 'Denza Z9');

      // Yangwang (R-brand)
      case 'R1':
        return ('yangwang_r1', 'Yangwang R1');
      case 'R2':
        return ('yangwang_r2', 'Yangwang R2');
      case 'R3':
        return ('yangwang_r3', 'Yangwang R3');
      case 'R4':
        return ('yangwang_r4', 'Yangwang R4');

      case 'unknown':
        return null;
    }
    // New carType BYD added in a ROM update we haven't seen yet —
    // surfaces in Sentry via [bydCarType], stays variant=null until
    // a row is added here.
    return null;
  }

  /// Nameplate (`persist.sys.byd.default_name`) → (variantId, name) for
  /// trims that report no usable carType/vehicleId on the sysprop path.
  /// Match tokens precisely so powertrain-distinct siblings don't collide
  /// (a BEV Sealion 06 EV must NOT resolve to this PHEV profile).
  static (String, String)? _resolveByDefaultName(String? defaultName) {
    if (defaultName == null || defaultName.isEmpty) return null;
    // BYD Sealion 06 EV (海狮06EV) — Di5.0 / BYD-container BEV. Defensive
    // fallback for an EV unit that reports code40d=0 (no integer): the
    // live 2025 unit exposes code40d=201 and resolves at the vehicleId
    // tier above, but match the precise 'EV' token here so it can never
    // collide with the PHEV DM-i below. Checked BEFORE the DM-i so the
    // distinct tokens don't overlap.
    if (defaultName.contains('海狮06EV')) {
      return ('sealion6_ev', 'BYD Sealion 06 EV');
    }
    // BYD Sealion 6 DM-i (海狮06DM-i) — Di5.0 / BYD-container PHEV. Live
    // 2026-06-13 (adb 127.0.0.1:5999): model_variant=unknown + code40d=0,
    // so neither the (carType,vehicleId) nor the integer path fires. Match
    // the 'DM' token so the PHEV and the BEV Sealion 06 EV (海狮06EV,
    // handled above) resolve to their own powertrain-correct profiles.
    if (defaultName.contains('海狮06DM')) {
      return ('sealion6_dmi', 'BYD Sealion 6 DM-i');
    }
    // BYD Song PLUS (宋PLUS) — Di5.0 / BYD-container. Live 2026-06-16
    // (adb 127.0.0.1:5999): a real Song PLUS reporting code40d=0 +
    // model_variant=unknown, so the (carType, vehicleId) and integer
    // paths all miss — `persist.sys.byd.default_name=宋PLUS` is the only
    // signal. Without this it fell through to GENERIC_DI50 ("Generic BYD
    // Di5.0") and showed as an unidentified car. Resolves to the base
    // PHEV profile (the common Song PLUS DM-i; this unit reports
    // energytype=2). The pure-EV Smart Drive reports code40d=330 and
    // resolves at tier 2 BEFORE reaching here, so it is unaffected; a
    // hypothetical code40d=0 EV unit would mis-tag as base here, but the
    // only delta is battery-only vs battery+fuel UX (same Di5.0 /
    // DiShare transport + cluster topology either way).
    if (defaultName.contains('宋PLUS')) {
      return ('song_plus', 'Song PLUS');
    }
    // BYD Song Pro (宋Pro) — Di5.0 / BYD-container PHEV. Live 2026-06-17
    // (adb 127.0.0.1:5999): default_name=宋Pro, ro.vehicle.type=
    // DiLink100_7.0UI (→ di5.0), code40d=0, model_variant=unknown — so the
    // (carType,vehicleId) and integer paths all miss; the nameplate is the
    // only signal. The 宋PLUS branch above does NOT match 宋Pro (distinct
    // tokens), so without this it fell through to GENERIC_DI50 and showed
    // as an unidentified car. Same DI50_BYD_DISHARE archetype as Song PLUS.
    if (defaultName.contains('宋Pro')) {
      return ('song_pro', 'Song Pro');
    }
    // BYD Qin L (秦L) — Di5.0 / BYD-container PHEV. Live 2026-06-17 (adb
    // 127.0.0.1:5999): default_name=秦L, Di5.0_5.0UI (→ di5.0), code40d=0,
    // model_variant=unknown, energytype=2 — every structured path misses;
    // the nameplate is the only signal. Same DI50_BYD_DISHARE archetype as
    // Song Pro. Without this it fell through to GENERIC_DI50.
    if (defaultName.contains('秦L')) {
      return ('qin_l', 'Qin L');
    }
    // BYD Qin Plus (秦Plus) — Di5.0 / BYD-container PHEV. Live 2026-06-18
    // (adb 127.0.0.1:5999): default_name=秦Plus, DiLink100_7.0UI (→ di5.0),
    // code40d=0, model_variant=unknown, energytype=2 — every structured path
    // misses; the nameplate is the only signal. Distinct token from 秦L
    // (Qin L) so the two don't collide. Same DI50_BYD_DISHARE archetype.
    if (defaultName.contains('秦Plus')) {
      return ('qin_plus', 'Qin Plus');
    }
    return null;
  }

  /// Reverse of [_resolveModel] — keeps override-driven friendly
  /// labels aligned with auto-detected ones. Updated alongside
  /// [_resolveModel].
  static const Map<String, String> _kFriendlyNames = <String, String>{
    'l8': 'Leopard 8',
    'l8_dk': 'Leopard 8',
    'l5': 'Leopard 5',
    'l5_nav': 'Leopard 5 Navigator',
    'l5l': 'Leopard 5 Lidar',
    'l5u': 'Leopard 5 Ultra',
    'l7': 'Leopard 7',
    'han_l': 'BYD HAN L',
    '5f': 'F-series',
    'song_plus': 'Song PLUS',
    'song_plus_sd': 'Song PLUS Smart Drive',
    'song_pro': 'Song Pro',
    'qin_l': 'Qin L',
    'qin_plus': 'Qin Plus',
    'fcbsf': 'FangChengBao FCBSF',
    'fcbsq': 'FangChengBao FCBSQ',
    'fcbure': 'FangChengBao FCBURE',
    'han': 'BYD Han',
    'tang': 'BYD Tang',
    'song': 'BYD Song',
    'qin': 'BYD Qin',
    'xia': 'BYD Xia',
    'seal': 'BYD Seal',
    'sealion': 'BYD Sealion',
    'sealion6_dmi': 'BYD Sealion 6 DM-i',
    'sealion6_ev': 'BYD Sealion 06 EV',
    'dolphin': 'BYD Dolphin',
    'denza_n7': 'Denza N7',
    'denza_n8': 'Denza N8',
    'denza_n9': 'Denza N9',
    'denza_d9': 'Denza D9',
    'denza_z9': 'Denza Z9',
    'yangwang_r1': 'Yangwang R1',
    'yangwang_r2': 'Yangwang R2',
    'yangwang_r3': 'Yangwang R3',
    'yangwang_r4': 'Yangwang R4',
  };
}

/// One-shot Riverpod accessor. The future resolves on the first
/// read; every consumer afterwards gets the cached value
/// synchronously via `requireValue`.
final modelDetectorProvider = FutureProvider<ModelId>((ref) async {
  return ModelDetector.detect();
});
