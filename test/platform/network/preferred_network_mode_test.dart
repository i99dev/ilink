import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/platform/network/preferred_network_mode.dart';

void main() {
  group('PreferredNetworkMode.allowedTypesBitmask (modem wire — pinned)', () {
    // These integers are passed verbatim to
    // `cmd phone set-allowed-network-types-for-users <BITMASK>` on
    // the radio. They are `TelephonyManager.NETWORK_TYPE_BITMASK_*`
    // = 1 << (NETWORK_TYPE - 1). A change here changes what the
    // modem is forced onto — it must be deliberate, hence pinned.
    test('2G = GSM|GPRS|EDGE = 32771', () {
      expect(PreferredNetworkMode.twoG.allowedTypesBitmask, 32771);
    });

    test('3G = UMTS|HSDPA|HSUPA|HSPA|HSPAP = 17284', () {
      expect(PreferredNetworkMode.threeG.allowedTypesBitmask, 17284);
    });

    test('4G = LTE-only = 4096 (matches fourG "LTE-only" semantics)', () {
      expect(PreferredNetworkMode.fourG.allowedTypesBitmask, 4096);
      expect(PreferredNetworkMode.fourG.id, 11);
    });

    test('AUTO = LTE|3G|2G = 54151 (no NR — no head-unit hardware)', () {
      expect(PreferredNetworkMode.auto.allowedTypesBitmask, 54151);
      // NR bit (1<<19 = 524288) must NOT be set on AUTO.
      expect(PreferredNetworkMode.auto.allowedTypesBitmask & 524288, 0);
    });

    test('5G = AUTO|NR = 578439', () {
      expect(PreferredNetworkMode.fiveG.allowedTypesBitmask, 578439);
      expect(PreferredNetworkMode.fiveG.allowedTypesBitmask & 524288, 524288);
    });

    test('AUTO is a strict superset of 2G/3G/4G bits', () {
      final auto = PreferredNetworkMode.auto.allowedTypesBitmask;
      for (final m in [
        PreferredNetworkMode.twoG,
        PreferredNetworkMode.threeG,
        PreferredNetworkMode.fourG,
      ]) {
        expect(
          auto & m.allowedTypesBitmask,
          m.allowedTypesBitmask,
          reason: '${m.label} bits must all be present in AUTO',
        );
      }
    });

    test('every mode has a non-zero bitmask (never force "no radio")', () {
      for (final m in [
        PreferredNetworkMode.auto,
        PreferredNetworkMode.fiveG,
        PreferredNetworkMode.fourG,
        PreferredNetworkMode.threeG,
        PreferredNetworkMode.twoG,
      ]) {
        expect(m.allowedTypesBitmask, greaterThan(0), reason: m.label);
      }
    });
  });

  group('PreferredNetworkMode.fromId / all', () {
    test('picker surfaces exactly Auto / 4G / 2G', () {
      expect(PreferredNetworkMode.all, [
        PreferredNetworkMode.auto,
        PreferredNetworkMode.fourG,
        PreferredNetworkMode.twoG,
      ]);
    });

    test('fromId resolves surfaced ids, null for unsurfaced/unknown', () {
      expect(PreferredNetworkMode.fromId(9), PreferredNetworkMode.auto);
      expect(PreferredNetworkMode.fromId(11), PreferredNetworkMode.fourG);
      expect(PreferredNetworkMode.fromId(1), PreferredNetworkMode.twoG);
      // 36 (5G) / 2 (3G) are defined but not in `all` → not resolved.
      expect(PreferredNetworkMode.fromId(36), isNull);
      expect(PreferredNetworkMode.fromId(2), isNull);
      expect(PreferredNetworkMode.fromId(999), isNull);
      expect(PreferredNetworkMode.fromId(null), isNull);
    });
  });

  group('NetworkModeWriteOutcome', () {
    test('via defaults to reverted (back-compat for set())', () {
      const o = NetworkModeWriteOutcome(ok: false, value: null);
      expect(o.via, NetworkModeApplied.reverted);
    });

    test('forceApply outcomes carry an explicit via', () {
      const ok = NetworkModeWriteOutcome(
        ok: true,
        value: 9,
        via: NetworkModeApplied.modem,
      );
      const fallback = NetworkModeWriteOutcome(
        ok: false,
        value: 1,
        via: NetworkModeApplied.radioInfo,
      );
      expect(ok.via, NetworkModeApplied.modem);
      expect(ok.ok, isTrue);
      expect(fallback.via, NetworkModeApplied.radioInfo);
      expect(fallback.ok, isFalse);
    });
  });
}
