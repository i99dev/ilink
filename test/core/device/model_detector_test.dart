import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/brands/byd/identity/byd_model_detector.dart';
import 'package:ilink/features/mini_apps/runtime/display_snapshot.dart';

/// Pins the (carType, vehicleId, dilinkRaw) -> ModelId resolution for
/// every BYD model the detector can identify. Driven by BYD's own
/// `ICarInfoManager` SDK shape — see `BydCarInfoBinder.kt` for the
/// source-of-truth field names. A regression here means the
/// textproto's `model_match` selector stops matching and the
/// dispatcher silently routes to the wrong variant — exactly the
/// bug we built the detector to prevent.
void main() {
  group('ModelDetector.classifyForTest', () {
    // ── Live-unit fixtures ───────────────────────────────────────
    test('Leopard 8 — live sysprop fixture (FCBSQ + 155)', () {
      // Pulled from the L8 dev unit at 192.168.4.72 on 2026-05-10:
      //   persist.sys.model_variant.model = "fcbsq"
      //   persist.sys.vehicle_40d_code = "155"
      //   persist.sys.byd.default_name = "豹8" (informational)
      //   ro.vehicle.type = "Di5.1_5.0UI"
      //
      // The Kotlin BydCarInfoBinder uppercases model_variant.model
      // → carType = "FCBSQ" and parses code40d → vehicleId = 155.
      // Variant resolves from the (carType, vehicleId) pair.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'vehicleId': 155,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('l8'));
      expect(m.friendlyName, equals('Leopard 8'));
      expect(m.dilinkFamily, equals('di5.1'));
      expect(m.bydCarType, equals('FCBSQ'));
      expect(m.vehicleId, equals(155));
      expect(m.id, equals('l8'));
    });

    test('Leopard 8 — framework-path fixture (richer fields)', () {
      // When the BYD SDK reflection succeeds (system-signed install),
      // the snapshot also carries brand / bodyType / VIN /
      // powerType / driverSeat. Variant resolution is identical.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'brand': 'F',
        'bodyType': 'SUV',
        'vehicleId': 155,
        'vin': 'LGXC79DA9R0123456',
        'powerType': 2,
        'driverSeat': 0,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('l8'));
      expect(m.brand, equals('F'));
      expect(m.bodyType, equals('SUV'));
      expect(m.vin, equals('LGXC79DA9R0123456'));
      expect(m.powerType, equals(2));
    });

    test(
      'Phase A — make / headUnit / region fold into ModelId from sysprops',
      () {
        // The 3 non-binder signals (Build.MANUFACTURER + ro.product.model
        // + gsm.sim.operator.iso-country) ride alongside the BYD SDK
        // payload. ModelDetectorChannel adds them to the carInfo map
        // so the sign-in fingerprint has ONE source of truth instead
        // of a parallel sysprop fan-out via CarIdentity.localOnly().
        final m = ModelDetector.classifyForTest({
          'carType': 'FCBSQ',
          'brand': 'F',
          'vehicleId': 155,
          'dilinkRaw': 'Di5.1_5.0UI',
          'make': 'BYD',
          'headUnit': 'DiLink5.1',
          'region': 'ae',
        });
        expect(m.make, equals('BYD'));
        expect(m.headUnit, equals('DiLink5.1'));
        expect(m.region, equals('ae'));
        // BYD-binder fields still resolved correctly alongside.
        expect(m.variant, equals('l8'));
        expect(m.bydCarType, equals('FCBSQ'));
      },
    );

    test('Phase A — null / missing / blank Phase-A fields stay null', () {
      // Emulator + restricted SELinux + missing SIM all return null
      // for the new fields. Defensive parsing keeps null-null vs
      // empty-string-null collapsed to a single shape.
      final missing = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'vehicleId': 155,
        'dilinkRaw': 'Di5.1',
      });
      expect(missing.make, isNull);
      expect(missing.headUnit, isNull);
      expect(missing.region, isNull);

      final blank = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'vehicleId': 155,
        'dilinkRaw': 'Di5.1',
        'make': '',
        'headUnit': '',
        'region': '',
      });
      expect(blank.make, isNull);
      expect(blank.headUnit, isNull);
      expect(blank.region, isNull);
    });

    test('ModelId.unknown carries null for the Phase-A fields', () {
      expect(ModelId.unknown.make, isNull);
      expect(ModelId.unknown.headUnit, isNull);
      expect(ModelId.unknown.region, isNull);
    });

    test('Leopard 5 — (FCBSF + 153)', () {
      // Per Leopard5.kt: code40d=153, modelVariant=fcbsf.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSF',
        'vehicleId': 153,
        'dilinkRaw': 'Di5.0_5.0UI',
      });
      expect(m.variant, equals('l5'));
      expect(m.friendlyName, equals('Leopard 5'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('Leopard 5 Ultra — (FCBSF + 304, Di5.1/XDJA)', () {
      // Live-validated 2026-06-11 on a real Leopard 5 Ultra
      // (adb 127.0.0.1:5999): model_variant=fcbsf, code40d=304,
      // ro.vehicle.type Di5.1_5.0UI, default_name 豹5, and the full
      // 5-display XDJA topology (cluster on display 5). Shares the
      // FCBSF carType with the Di5.0 L5 base (153) but the code40d
      // pins the Di5.1 Ultra → the existing DI51_XDJA_CLUSTER
      // LEOPARD5_ULTRA_PROFILE. Was falling to the 'fcbsf' family stub.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSF',
        'vehicleId': 304,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('l5u'));
      expect(m.friendlyName, equals('Leopard 5 Ultra'));
      expect(m.dilinkFamily, equals('di5.1'));
    });

    test('Leopard 5 Navigator — (FCBSF + code40d 0, Di5.0)', () {
      // Live 2026-06-20 (adb 127.0.0.1:5999): model_variant=fcbsf,
      // vehicle_40d_code=0 (UNSET), default_name 豹5, Di5.0_5.0UI,
      // energytype=2. Base L5 keys on 153 and L5 Ultra on 304; this unit
      // exposes neither, so it was falling to the 'fcbsf' family stub.
      // carType FCBSF + code40d=0 + Di5.0 pins it → LEOPARD5_NAVIGATOR
      // (DI50_BYD_DISHARE, behaviour identical to base L5).
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSF',
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '豹5',
      });
      expect(m.variant, equals('l5_nav'));
      expect(m.friendlyName, equals('Leopard 5 Navigator'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('FCBSF + code40d 0 but NOT Di5.0 does NOT grab the Navigator '
        '(Di5.0 gate)', () {
      // Guard: a future Di5.1 FCBSF with an unset code must fall to the
      // family stub, never the Di5.0 DiShare Navigator profile.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSF',
        'vehicleId': 0,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, isNot(equals('l5_nav')));
    });

    test(
      'Song PLUS — vehicleId 243 with no carType (modelVariant=unknown)',
      () {
        // SongPlus.kt notes: BYD doesn't populate
        // `persist.sys.model_variant.model` for Song PLUS — it
        // reports "unknown". The vehicleId-only resolution path
        // (code40d=243) catches this case.
        final m = ModelDetector.classifyForTest({
          'carType': null,
          'vehicleId': 243,
          'dilinkRaw': 'Di5.0_5.0UI',
        });
        expect(m.variant, equals('song_plus'));
        expect(m.friendlyName, equals('Song PLUS'));
        expect(m.dilinkFamily, equals('di5.0'));
      },
    );

    test('Song PLUS Smart Drive — vehicleId 330, no carType (BEV, Di5.0)', () {
      // Live-validated 2026-06-12 (adb 127.0.0.1:5999): default_name
      // 宋PLUS, Di5.0_5.0UI, code40d=330 (base Song PLUS is 243; both
      // report model_variant.model="unknown" so carType is null and the
      // vehicleId-only path resolves it). energytype=1 → BEV →
      // SONG_PLUS_SD_PROFILE (DI50_BYD_DISHARE + Powertrain.Ev).
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 330,
        'dilinkRaw': 'Di5.0_5.0UI',
      });
      expect(m.variant, equals('song_plus_sd'));
      expect(m.friendlyName, equals('Song PLUS Smart Drive'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test(
      'Leopard 7 — vehicleId 282 + carType "QZ" (sysprop fallback path)',
      () {
        // Live-validated 2026-06-11 on a real L7 (adb 127.0.0.1:5999):
        // sysprop fallback gives model_variant.model="qz" → carType
        // "QZ" (NOT an FCB enum value, so the tier-1 carType switch
        // misses it) and vehicle_40d_code=282. The vehicleId-only
        // path (code40d=282) is what catches L7, mirroring Song PLUS.
        // dilinkRaw uses the public marketing-number form DiLink150.
        final m = ModelDetector.classifyForTest({
          'carType': 'QZ',
          'vehicleId': 282,
          'dilinkRaw': 'DiLink150_7.0UI',
        });
        expect(m.variant, equals('l7'));
        expect(m.friendlyName, equals('Leopard 7'));
        expect(m.dilinkFamily, equals('di5.1'));
        expect(m.id, equals('l7'));
      },
    );

    test('Leopard 7 with unset code40d — carType "QZ" + vehicleId 0', () {
      // Live 2026-06-12 on a 2nd L7: same qz / DiLink150_7.0UI / 钛7 /
      // outsw 34.1.35 as the first, but vehicle_40d_code=0 (unset) + a
      // different VIN. The code40d path (282) misses, so resolution must
      // fall back to the carType "QZ" token → l7 (not GENERIC_DI51).
      final m = ModelDetector.classifyForTest({
        'carType': 'QZ',
        'vehicleId': 0,
        'dilinkRaw': 'DiLink150_7.0UI',
      });
      expect(m.variant, equals('l7'));
      expect(m.friendlyName, equals('Leopard 7'));
      expect(m.dilinkFamily, equals('di5.1'));
    });

    test('Sealion 6 DM-i — default_name 海狮06DM-i (no carType, code40d 0)', () {
      // Live 2026-06-13 (adb 127.0.0.1:5999): model_variant.model=unknown
      // (→ carType null) and vehicle_40d_code=0 (→ vehicleId 0), so neither
      // the (carType,vehicleId) nor the integer path can pin it. Resolution
      // keys on the nameplate persist.sys.byd.default_name = 海狮06DM-i,
      // threaded through BydCarInfoBinder → the channel map → _classify.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮06DM-i',
      });
      expect(m.variant, equals('sealion6_dmi'));
      expect(m.friendlyName, equals('BYD Sealion 6 DM-i'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('Sealion 06 EV — code40d 201 (live 2025 unit)', () {
      // Live 2026-06-19 (adb 127.0.0.1:5999): the real Sealion 06 EV
      // reports model_variant=unknown (carType null) + vehicle_40d_code
      // =201 + default_name 海狮06EV + energytype=1. The integer tier pins
      // it to sealion6_ev (BEV) — its own profile, NOT the PHEV DM-i nor
      // the GENERIC_DI50 stub.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 201,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮06EV',
      });
      expect(m.variant, equals('sealion6_ev'));
      expect(m.friendlyName, equals('BYD Sealion 06 EV'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('Sealion 06 EV nameplate resolves to the BEV profile, NOT the '
        'PHEV DM-i', () {
      // Defensive: an EV unit reporting code40d=0 (no integer) still
      // resolves via the precise 海狮06EV nameplate token — and must NOT
      // collide with the PHEV sealion6_dmi (海狮06DM).
      final ev = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮06EV',
      });
      expect(ev.variant, equals('sealion6_ev'));
      // The DM-i token still resolves to the PHEV profile (no overlap).
      final dmi = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮06DM-i',
      });
      expect(dmi.variant, equals('sealion6_dmi'));
    });

    test('Song PLUS — default_name 宋PLUS (no carType, code40d 0)', () {
      // Live 2026-06-16 (adb 127.0.0.1:5999): a real Song PLUS reporting
      // model_variant.model=unknown (→ carType null) + vehicle_40d_code=0
      // (→ vehicleId 0), so the (carType,vehicleId) and integer paths all
      // miss. Without a nameplate entry it fell through to GENERIC_DI50
      // and surfaced as an unidentified "Generic BYD Di5.0". The
      // persist.sys.byd.default_name=宋PLUS nameplate now resolves it.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '宋PLUS',
      });
      expect(m.variant, equals('song_plus'));
      expect(m.friendlyName, equals('Song PLUS'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test(
      'Song PLUS Smart Drive (code40d 330) still wins over the nameplate',
      () {
        // The EV Smart Drive reports code40d=330 → resolves at the integer
        // tier BEFORE the nameplate fallback, so adding the 宋PLUS nameplate
        // entry must NOT regress it to the base song_plus.
        final m = ModelDetector.classifyForTest({
          'carType': null,
          'vehicleId': 330,
          'dilinkRaw': 'Di5.0_5.0UI',
          'defaultName': '宋PLUS',
        });
        expect(m.variant, equals('song_plus_sd'));
      },
    );

    test('Song Pro — default_name 宋Pro (no carType, code40d 0)', () {
      // Live 2026-06-17 (adb 127.0.0.1:5999): a real Song Pro reporting
      // model_variant.model=unknown (→ carType null) + vehicle_40d_code=0,
      // ro.vehicle.type=DiLink100_7.0UI (→ di5.0). Both structured paths
      // miss; the persist.sys.byd.default_name=宋Pro nameplate resolves it.
      // Distinct token from 宋PLUS so the two don't collide.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'DiLink100_7.0UI',
        'defaultName': '宋Pro',
      });
      expect(m.variant, equals('song_pro'));
      expect(m.friendlyName, equals('Song Pro'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('Qin L — default_name 秦L (no carType, code40d 0)', () {
      // Live 2026-06-17 (adb 127.0.0.1:5999): Qin L reporting carType null +
      // code40d 0, Di5.0_5.0UI (→ di5.0), energytype=2. Structured paths
      // miss; persist.sys.byd.default_name=秦L resolves it. Same Di5.0 /
      // DI50_BYD_DISHARE archetype as Song Pro.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '秦L',
      });
      expect(m.variant, equals('qin_l'));
      expect(m.friendlyName, equals('Qin L'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('Qin Plus — default_name 秦Plus (no carType, code40d 0)', () {
      // Live 2026-06-18 (adb 127.0.0.1:5999): Qin Plus, carType null +
      // code40d 0, DiLink100_7.0UI (→ di5.0), energytype=2. Structured paths
      // miss; persist.sys.byd.default_name=秦Plus resolves it. Distinct token
      // from 秦L (Qin L). Same DI50_BYD_DISHARE archetype.
      final m = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'DiLink100_7.0UI',
        'defaultName': '秦Plus',
      });
      expect(m.variant, equals('qin_plus'));
      expect(m.friendlyName, equals('Qin Plus'));
      expect(m.dilinkFamily, equals('di5.0'));
    });

    test('秦Plus and 秦L nameplates do NOT cross-resolve', () {
      final plus = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '秦Plus',
      });
      final l = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '秦L',
      });
      expect(plus.variant, equals('qin_plus'));
      expect(l.variant, equals('qin_l'));
    });

    test('宋Pro and 宋PLUS nameplates do NOT cross-resolve', () {
      // Guard the substring matches against each other.
      final pro = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '宋Pro',
      });
      final plus = ModelDetector.classifyForTest({
        'carType': null,
        'vehicleId': 0,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '宋PLUS',
      });
      expect(pro.variant, equals('song_pro'));
      expect(plus.variant, equals('song_plus'));
    });

    test('Sealion 6 DM-i — nameplate wins over the SEALION carType stub', () {
      // On a platform-signed install the framework returns carType SEALION
      // (the whole Ocean Sealion line → the coarse 'sealion' stub). The
      // nameplate disambiguation runs BEFORE the carType map, so a
      // 海狮06DM-i unit resolves to the precise sealion6_dmi, not the stub.
      final m = ModelDetector.classifyForTest({
        'carType': 'SEALION',
        'vehicleId': -1,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮06DM-i',
      });
      expect(m.variant, equals('sealion6_dmi'));
    });

    test('A non-Sealion-6 SEALION still resolves to the sealion stub', () {
      // carType SEALION with no 海狮06DM nameplate (e.g. a Seal / Sealion 07)
      // — the nameplate guard misses, so the coarse carType map yields the
      // 'sealion' family stub as before (no regression).
      final m = ModelDetector.classifyForTest({
        'carType': 'SEALION',
        'vehicleId': -1,
        'dilinkRaw': 'Di5.0_5.0UI',
        'defaultName': '海狮07',
      });
      expect(m.variant, equals('sealion'));
    });

    // ── FangChengBao FCBSQ == Leopard 8 (family-wide) ────────────
    test('FCBSQ with any vehicleId resolves to l8 (FCBSQ is L8-only)', () {
      // FCBSQ is the Leopard 8 family. Base L8 is code40d=155, but the
      // DJI-drone-kit unit reports code40d=0 (framework getVehicleId()
      // =31) — both must get the XDJA-cluster l8 profile, NOT the
      // GENERIC_DI51 'fcbsq' stub. An unmapped code40d therefore stays
      // l8 (live 2026-06-19, adb 127.0.0.1:5999, default_name 豹8).
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'vehicleId': 999,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('l8'));
      expect(m.friendlyName, equals('Leopard 8'));
    });

    test('Leopard 8 drone-kit unit — FCBSQ + code40d 0/31 -> l8_dk', () {
      // Live 2026-06-19 (adb 127.0.0.1:5999): BYD Leopard 8 with the DJI
      // drone kit. model_variant=fcbsq → carType FCBSQ, code40d=0
      // (sysprop unset; framework getVehicleId()=31), default_name 豹8,
      // Di5.1_5.0UI. Same vehicle as base L8 but a different XDJA display
      // ROM (FSE on display 2, cluster split on 3+4, no display 5) → its
      // own l8_dk profile. Both the sysprop (0) and framework (31) forms
      // must resolve l8_dk, not the standard l8 (whose display map would
      // hide the cluster) nor the GENERIC_DI51 'fcbsq' stub.
      for (final vid in [0, 31]) {
        final m = ModelDetector.classifyForTest({
          'carType': 'FCBSQ',
          'vehicleId': vid,
          'dilinkRaw': 'Di5.1_5.0UI',
          'defaultName': '豹8',
        });
        expect(m.variant, equals('l8_dk'), reason: 'vehicleId=$vid');
        expect(m.friendlyName, equals('Leopard 8'));
        expect(m.dilinkFamily, equals('di5.1'));
      }
    });

    test('FCBSF with unmapped vehicleId -> family fallback', () {
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSF',
        'vehicleId': 998,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('fcbsf'));
    });

    test('FCBURE -> family-level variant', () {
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBURE',
        'vehicleId': 17,
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('fcbure'));
    });

    // ── Dynasty ──────────────────────────────────────────────────
    test('HAN', () {
      final m = ModelDetector.classifyForTest({
        'carType': 'HAN',
        'brand': 'DYNASTY',
        'bodyType': 'CAR',
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('han'));
      expect(m.friendlyName, equals('BYD Han'));
      expect(m.brand, equals('DYNASTY'));
      expect(m.dilinkFamily, equals('di5.1'));
    });

    test('TANG', () {
      final m = ModelDetector.classifyForTest({
        'carType': 'TANG',
        'brand': 'DYNASTY',
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('tang'));
      expect(m.friendlyName, equals('BYD Tang'));
    });

    test('SONG / QIN / XIA', () {
      for (final entry in {
        'SONG': ('song', 'BYD Song'),
        'QIN': ('qin', 'BYD Qin'),
        'XIA': ('xia', 'BYD Xia'),
      }.entries) {
        final m = ModelDetector.classifyForTest({
          'carType': entry.key,
          'brand': 'DYNASTY',
          'dilinkRaw': 'Di5.1_5.0UI',
        });
        expect(m.variant, equals(entry.value.$1));
        expect(m.friendlyName, equals(entry.value.$2));
      }
    });

    // ── Ocean ────────────────────────────────────────────────────
    test('SEAL / SEALION / DOLPHIN', () {
      for (final entry in {
        'SEAL': ('seal', 'BYD Seal'),
        'SEALION': ('sealion', 'BYD Sealion'),
        'DOLPHIN': ('dolphin', 'BYD Dolphin'),
      }.entries) {
        final m = ModelDetector.classifyForTest({
          'carType': entry.key,
          'brand': 'OCEAN',
          'dilinkRaw': 'Di5.1_5.0UI',
        });
        expect(m.variant, equals(entry.value.$1));
        expect(m.friendlyName, equals(entry.value.$2));
        expect(m.brand, equals('OCEAN'));
      }
    });

    // ── Denza ────────────────────────────────────────────────────
    test('Denza family', () {
      for (final entry in {
        'N7': ('denza_n7', 'Denza N7'),
        'N8': ('denza_n8', 'Denza N8'),
        'N9': ('denza_n9', 'Denza N9'),
        'D9': ('denza_d9', 'Denza D9'),
        'Z9': ('denza_z9', 'Denza Z9'),
      }.entries) {
        final m = ModelDetector.classifyForTest({
          'carType': entry.key,
          'brand': 'DENZA',
          'dilinkRaw': 'Di5.1_5.0UI',
        });
        expect(m.variant, equals(entry.value.$1));
        expect(m.friendlyName, equals(entry.value.$2));
        expect(m.brand, equals('DENZA'));
      }
    });

    // ── Yangwang (R-brand) ───────────────────────────────────────
    test('Yangwang R-series', () {
      for (final entry in {
        'R1': ('yangwang_r1', 'Yangwang R1'),
        'R2': ('yangwang_r2', 'Yangwang R2'),
        'R3': ('yangwang_r3', 'Yangwang R3'),
        'R4': ('yangwang_r4', 'Yangwang R4'),
      }.entries) {
        final m = ModelDetector.classifyForTest({
          'carType': entry.key,
          'brand': 'R',
          'dilinkRaw': 'Di5.1_5.0UI',
        });
        expect(m.variant, equals(entry.value.$1));
        expect(m.friendlyName, equals(entry.value.$2));
      }
    });

    // ── Edge cases ───────────────────────────────────────────────
    test('SDK absent (empty map) -> unknown family, no variant', () {
      final m = ModelDetector.classifyForTest({});
      expect(m.variant, isNull);
      expect(m.friendlyName, isNull);
      expect(m.dilinkFamily, equals('unknown'));
      expect(m.id, equals('unknown'));
      expect(m.bydCarType, isNull);
      expect(m.vehicleId, equals(-1));
    });

    test('carType=unknown -> variant null, dilinkFamily preserved', () {
      // SDK returns "unknown" when the framework couldn't resolve
      // a carType (corrupt prop, non-BYD ROM behind a BYD-style
      // overlay). dilinkFamily still resolves from dilinkRaw so
      // family-level routes keep working.
      final m = ModelDetector.classifyForTest({
        'carType': 'unknown',
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, isNull);
      expect(m.bydCarType, isNull);
      expect(m.dilinkFamily, equals('di5.1'));
      expect(m.id, equals('di5.1'));
    });

    test(
      'unrecognised future carType -> variant null, bydCarType preserved',
      () {
        // BYD adds a new model in a ROM update we haven't profiled
        // yet. Resolver returns variant=null but the SDK string is
        // surfaced via bydCarType so triage can spot it in Sentry
        // and add the resolution row in the next minor release.
        final m = ModelDetector.classifyForTest({
          'carType': 'FUTURE_MODEL',
          'brand': 'DYNASTY',
          'vehicleId': 99,
          'dilinkRaw': 'Di5.1_5.0UI',
        });
        expect(m.variant, isNull);
        expect(
          m.bydCarType,
          equals('FUTURE_MODEL'),
          reason:
              'Unprofiled trims must surface the raw carType so triage '
              'can add the resolution row without re-running the user.',
        );
        expect(m.dilinkFamily, equals('di5.1'));
      },
    );

    test('Di5.0 family from dilinkRaw', () {
      final m = ModelDetector.classifyForTest({
        'carType': 'HAN',
        'dilinkRaw': 'Di5.0_4.0UI',
      });
      expect(m.dilinkFamily, equals('di5.0'));
      expect(m.variant, equals('han'));
    });

    test('Missing dilinkRaw -> dilinkFamily=unknown', () {
      final m = ModelDetector.classifyForTest({'carType': 'TANG'});
      expect(m.dilinkFamily, equals('unknown'));
      expect(m.variant, equals('tang'));
    });

    test('Public marketing-number dilinkRaw (DiLink150/DiLink100)', () {
      // ro.vehicle.type sometimes uses the public form (150 = 5.1,
      // 100 = 5.0) instead of the internal Di5.x form. Live on the
      // Leopard 7 ("DiLink150_7.0UI", 2026-06-11). Both must map to
      // the right generation so an unprofiled DiLink150 car falls to
      // GENERIC_DI51, not the permissive GENERIC_PROFILE.
      final di51 = ModelDetector.classifyForTest({
        'carType': 'TANG',
        'dilinkRaw': 'DiLink150_7.0UI',
      });
      expect(di51.dilinkFamily, equals('di5.1'));
      final di50 = ModelDetector.classifyForTest({
        'carType': 'TANG',
        'dilinkRaw': 'DiLink100_5.0UI',
      });
      expect(di50.dilinkFamily, equals('di5.0'));
    });

    test('vehicleId stringified by channel still parses', () {
      // Defensive — channel encoders sometimes coerce ints to
      // strings on certain Flutter versions. Resolver must accept
      // either shape.
      final m = ModelDetector.classifyForTest({
        'carType': 'FCBSQ',
        'vehicleId': '155',
        'dilinkRaw': 'Di5.1_5.0UI',
      });
      expect(m.variant, equals('l8'));
      expect(m.vehicleId, equals(155));
    });
  });

  group('DisplaySnapshot wire shape', () {
    test('round-trips new VehicleProfile fields', () {
      const s = DisplaySnapshot(
        id: 5,
        name: 'fission_bg',
        width: 1920,
        height: 720,
        densityDpi: 240,
        isDefault: false,
        isPresentation: false,
        isCluster: true,
        role: 'cluster',
        hidden: false,
        overrideLabel: 'Driver',
        clusterAvailable: true,
        cursorDisplayId: 5,
        inputSourceDisplayId: 3,
        zoomDisplayId: 5,
      );
      final json = s.toJson();
      final back = DisplaySnapshot.fromMap(json);
      expect(back.overrideLabel, equals('Driver'));
      expect(back.clusterAvailable, isTrue);
      expect(back.cursorDisplayId, equals(5));
      expect(back.inputSourceDisplayId, equals(3));
      expect(back.zoomDisplayId, equals(5));
      expect(back.hidden, isFalse);
    });

    test('older host without profile fields parses with safe defaults', () {
      // A host shipped before VehicleProfile wiring sends the
      // pre-2026-05 shape — no hidden / overrideLabel /
      // clusterAvailable / *DisplayId fields. Mini-apps should still
      // parse without throwing; defaults must be safe (cluster
      // available so we don't pre-emptively hide features; remap
      // ids fall back to displayId so input/cursor stay where the
      // OS put them).
      const oldShape = <String, Object?>{
        'id': 4,
        'name': 'IVI',
        'width': 1920,
        'height': 1200,
        'densityDpi': 240,
        'isDefault': true,
        'isPresentation': false,
        'isCluster': false,
        'role': 'ivi',
      };
      final back = DisplaySnapshot.fromMap(oldShape);
      expect(back.hidden, isFalse);
      expect(back.overrideLabel, isNull);
      expect(back.clusterAvailable, isTrue);
      expect(back.cursorDisplayId, equals(4));
      expect(back.inputSourceDisplayId, equals(4));
      expect(back.zoomDisplayId, equals(4));
    });
  });
}
