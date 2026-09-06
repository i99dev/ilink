import 'dart:math';

import 'package:flutter/foundation.dart';

/// One of the five Chinese carrier presets the SIM spoof picker
/// exposes. ICCID prefix + matching IMSI MCC/MNC are paired so anyone
/// checking both fields agrees on the same carrier — randomising the
/// trailing digits independently of the prefix would otherwise out
/// the spoof to any operator-aware consumer.
///
/// Range allocations from ITU-T E.118 (ICCID) and ITU-T E.212 (IMSI).
/// Pairings cross-checked against published 中国 carrier MNCs:
///   * China Mobile (CMCC) — 46000 / 89860 0; 46007 / 89860 7 (TD-LTE)
///   * China Unicom (CUCC) — 46001 / 89860 1
///   * China Telecom (CTCC) — 46003 / 89860 3; 46011 / 89861 1 (LTE)
@immutable
class ChineseCarrierPreset {
  const ChineseCarrierPreset({
    required this.id,
    required this.label,
    required this.iccidPrefix,
    required this.imsiMccMnc,
  });

  /// Stable kebab id used as the SharedPreferences key + history tag.
  final String id;

  /// Short display label rendered on the chip.
  final String label;

  /// 6-digit ICCID prefix `8986XX`. The 13 remaining subscriber digits
  /// + 1 Luhn check are generated per press.
  final String iccidPrefix;

  /// 5-digit MCC+MNC prefix (`460` + 2-digit MNC). The 10 remaining
  /// MSIN digits are generated per press to produce a 15-digit IMSI.
  final String imsiMccMnc;

  /// Human-readable carrier name for the Device Info "Operator" row
  /// when the spoof is active. The short [label] (CMCC/CUCC/…) is
  /// fine for the carrier chips but reads awkwardly in a full
  /// "Operator" cell — this gives the consumer-friendly form.
  String get displayName => switch (id) {
    'cmcc' => 'China Mobile',
    'cucc' => 'China Unicom',
    'ctcc' => 'China Telecom',
    'cmcc-lte' => 'China Mobile (LTE)',
    'ctcc-lte' => 'China Telecom (LTE)',
    _ => label,
  };

  static const cmcc = ChineseCarrierPreset(
    id: 'cmcc',
    label: 'CMCC',
    iccidPrefix: '898600',
    imsiMccMnc: '46000',
  );

  static const cucc = ChineseCarrierPreset(
    id: 'cucc',
    label: 'CUCC',
    iccidPrefix: '898601',
    imsiMccMnc: '46001',
  );

  static const ctcc = ChineseCarrierPreset(
    id: 'ctcc',
    label: 'CTCC',
    iccidPrefix: '898603',
    imsiMccMnc: '46003',
  );

  static const cmccLte = ChineseCarrierPreset(
    id: 'cmcc-lte',
    label: 'CM-LTE',
    iccidPrefix: '898607',
    imsiMccMnc: '46007',
  );

  static const ctccLte = ChineseCarrierPreset(
    id: 'ctcc-lte',
    label: 'CT-LTE',
    iccidPrefix: '898611',
    imsiMccMnc: '46011',
  );

  static const all = <ChineseCarrierPreset>[cmcc, cucc, ctcc, cmccLte, ctccLte];

  static ChineseCarrierPreset? fromId(String? id) {
    if (id == null) return null;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// A generated SIM-identity pair. Both strings carry the carrier
/// prefix the user picked; only the subscriber digits + ICCID check
/// digit vary per generation.
@immutable
class GeneratedSimIdentity {
  const GeneratedSimIdentity({
    required this.carrier,
    required this.iccid,
    required this.imsi,
    required this.generatedAt,
  });

  final ChineseCarrierPreset carrier;

  /// 20-digit ICCID with valid Luhn check digit.
  final String iccid;

  /// 15-digit IMSI (3 MCC + 2 MNC + 10 MSIN).
  final String imsi;

  /// Wall-clock time of generation — surfaced in the history row so
  /// the user can tell stale picks from fresh ones at a glance.
  final DateTime generatedAt;

  GeneratedSimIdentity copyWith({DateTime? generatedAt}) =>
      GeneratedSimIdentity(
        carrier: carrier,
        iccid: iccid,
        imsi: imsi,
        generatedAt: generatedAt ?? this.generatedAt,
      );

  Map<String, dynamic> toJson() => {
    'carrierId': carrier.id,
    'iccid': iccid,
    'imsi': imsi,
    'generatedAt': generatedAt.toIso8601String(),
  };

  static GeneratedSimIdentity? fromJson(Map<String, dynamic> json) {
    final carrier = ChineseCarrierPreset.fromId(json['carrierId'] as String?);
    final iccid = json['iccid'] as String?;
    final imsi = json['imsi'] as String?;
    final generatedAtStr = json['generatedAt'] as String?;
    if (carrier == null || iccid == null || imsi == null) return null;
    final generatedAt = generatedAtStr == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : (DateTime.tryParse(generatedAtStr) ??
              DateTime.fromMillisecondsSinceEpoch(0));
    return GeneratedSimIdentity(
      carrier: carrier,
      iccid: iccid,
      imsi: imsi,
      generatedAt: generatedAt,
    );
  }
}

/// Generator for [GeneratedSimIdentity]. Pure-Dart, testable, no
/// platform deps. Accepts an injectable [Random] so tests can pin the
/// trailing digits without monkey-patching the global.
class IccidImsiGenerator {
  IccidImsiGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  GeneratedSimIdentity generate(ChineseCarrierPreset carrier, {DateTime? now}) {
    final iccid = _iccidFor(carrier);
    final imsi = _imsiFor(carrier);
    return GeneratedSimIdentity(
      carrier: carrier,
      iccid: iccid,
      imsi: imsi,
      generatedAt: now ?? DateTime.now(),
    );
  }

  String _iccidFor(ChineseCarrierPreset carrier) {
    // 6 prefix + 13 subscriber + 1 Luhn = 20.
    final subscriber = _randomDigits(13);
    final body = '${carrier.iccidPrefix}$subscriber';
    final check = luhnCheckDigit(body);
    return '$body$check';
  }

  String _imsiFor(ChineseCarrierPreset carrier) {
    // 5 (MCC+MNC) + 10 MSIN = 15. IMSI carries no checksum.
    final msin = _randomDigits(10);
    return '${carrier.imsiMccMnc}$msin';
  }

  String _randomDigits(int count) {
    final buf = StringBuffer();
    for (var i = 0; i < count; i++) {
      buf.write(_random.nextInt(10));
    }
    return buf.toString();
  }
}

/// Standard Luhn (mod-10) check digit. Doubles every second digit
/// from the right of [digits]; if doubling produces a two-digit
/// value, the digits are summed (equivalent to subtracting 9). The
/// returned digit is the one that, appended to [digits], makes the
/// whole string Luhn-valid.
///
/// Visible at top-level so the unit test in
/// `test/kernel/sim/iccid_imsi_generator_test.dart` can exercise it
/// against the published worked examples without going through the
/// generator wrapper.
int luhnCheckDigit(String digits) {
  var sum = 0;
  var doubleIt = true;
  for (var i = digits.length - 1; i >= 0; i--) {
    final code = digits.codeUnitAt(i) - 0x30;
    assert(code >= 0 && code <= 9, 'non-digit in luhn input: $digits');
    var d = code;
    if (doubleIt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubleIt = !doubleIt;
  }
  return (10 - (sum % 10)) % 10;
}

/// True when [digits] is Luhn-valid (the last digit is the correct
/// check digit for the rest). Exposed for the readback path that
/// validates a user-pasted ICCID before persisting.
bool isLuhnValid(String digits) {
  if (digits.length < 2) return false;
  final body = digits.substring(0, digits.length - 1);
  final claimed = digits.codeUnitAt(digits.length - 1) - 0x30;
  if (claimed < 0 || claimed > 9) return false;
  return luhnCheckDigit(body) == claimed;
}
