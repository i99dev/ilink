import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/sim/iccid_imsi_generator.dart';

void main() {
  group('luhnCheckDigit', () {
    // Worked examples from ISO/IEC 7812 + Wikipedia's Luhn page.
    // Verified by hand: doubling 7,8,5,8 and summing all digits gives a
    // multiple of 10 only with check digit 3.
    test('classic example 79927398713 → check digit 3', () {
      expect(luhnCheckDigit('7992739871'), 3);
      expect(isLuhnValid('79927398713'), isTrue);
    });

    test('reject when last digit doesn\'t match', () {
      expect(isLuhnValid('79927398710'), isFalse);
      expect(isLuhnValid('79927398719'), isFalse);
    });

    test('handles a real ICCID body — append digit makes it valid', () {
      const body = '8986001234567890123'; // 19 digits, CMCC prefix
      final check = luhnCheckDigit(body);
      expect(check, inInclusiveRange(0, 9));
      expect(isLuhnValid('$body$check'), isTrue);
    });

    test('check digit is stable for the same input', () {
      const body = '8986031111222233334';
      expect(luhnCheckDigit(body), luhnCheckDigit(body));
    });
  });

  group('IccidImsiGenerator', () {
    test('every preset produces 20-digit Luhn-valid ICCID', () {
      // Random.secure() is fine for production; pin a seeded Random
      // here so a flake in this test cleanly maps to a regression and
      // not to RNG bias.
      final gen = IccidImsiGenerator(random: Random(42));
      for (final preset in ChineseCarrierPreset.all) {
        final result = gen.generate(preset);
        expect(
          result.iccid.length,
          20,
          reason: 'ICCID for ${preset.id} must be 20 digits',
        );
        expect(
          isLuhnValid(result.iccid),
          isTrue,
          reason: 'ICCID for ${preset.id} (${result.iccid}) failed Luhn',
        );
        expect(
          result.iccid.startsWith(preset.iccidPrefix),
          isTrue,
          reason: 'ICCID for ${preset.id} missing carrier prefix',
        );
      }
    });

    test('every preset produces 15-digit IMSI starting with MCC+MNC', () {
      final gen = IccidImsiGenerator(random: Random(7));
      for (final preset in ChineseCarrierPreset.all) {
        final result = gen.generate(preset);
        expect(result.imsi.length, 15, reason: 'IMSI must be 15 digits');
        expect(
          result.imsi.startsWith(preset.imsiMccMnc),
          isTrue,
          reason: 'IMSI for ${preset.id} missing MCC+MNC prefix',
        );
      }
    });

    test('successive generations differ in the subscriber digits', () {
      final gen = IccidImsiGenerator(random: Random(1));
      final a = gen.generate(ChineseCarrierPreset.cmcc);
      final b = gen.generate(ChineseCarrierPreset.cmcc);
      expect(a.iccid, isNot(b.iccid));
      expect(a.imsi, isNot(b.imsi));
    });
  });

  group('ChineseCarrierPreset', () {
    test('all 5 presets are distinct', () {
      final ids = ChineseCarrierPreset.all.map((p) => p.id).toSet();
      expect(ids.length, 5);
      final prefixes = ChineseCarrierPreset.all
          .map((p) => p.iccidPrefix)
          .toSet();
      expect(prefixes.length, 5);
      final mncs = ChineseCarrierPreset.all.map((p) => p.imsiMccMnc).toSet();
      expect(mncs.length, 5);
    });

    test('iccid prefix and imsi MCC+MNC agree per preset (last 2 digits)', () {
      // ICCID issuer id (digits 5-6 of 8986XX) and IMSI MNC (last 2 of
      // 460XX) must match per carrier to be plausible. This locks the
      // pairing table against a typo-mediated drift.
      for (final p in ChineseCarrierPreset.all) {
        expect(
          p.iccidPrefix.substring(4),
          p.imsiMccMnc.substring(3),
          reason: '${p.id} ICCID issuer ≠ IMSI MNC',
        );
      }
    });

    test('fromId round-trips via .all', () {
      for (final p in ChineseCarrierPreset.all) {
        expect(ChineseCarrierPreset.fromId(p.id), p);
      }
      expect(ChineseCarrierPreset.fromId(null), isNull);
      expect(ChineseCarrierPreset.fromId('not-a-real-id'), isNull);
    });
  });

  group('GeneratedSimIdentity', () {
    test('toJson + fromJson round-trip', () {
      final gen = IccidImsiGenerator(random: Random(99));
      final orig = gen.generate(ChineseCarrierPreset.ctcc);
      final round = GeneratedSimIdentity.fromJson(orig.toJson());
      expect(round, isNotNull);
      expect(round!.carrier.id, orig.carrier.id);
      expect(round.iccid, orig.iccid);
      expect(round.imsi, orig.imsi);
      expect(
        round.generatedAt.toIso8601String(),
        orig.generatedAt.toIso8601String(),
      );
    });

    test('fromJson returns null on missing required keys', () {
      expect(GeneratedSimIdentity.fromJson({}), isNull);
      expect(GeneratedSimIdentity.fromJson({'carrierId': 'cmcc'}), isNull);
      expect(
        GeneratedSimIdentity.fromJson({
          'carrierId': 'cmcc',
          'iccid': '12345',
          // missing imsi
        }),
        isNull,
      );
    });
  });
}
