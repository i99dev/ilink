import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ilink/kernel/sim/iccid_imsi_generator.dart';
import 'package:ilink/kernel/sim/sim_identity_override.dart';

void main() {
  group('SimIdentityOverrideController', () {
    setUp(() {
      // The plugin's method channel is wired to an in-memory map by
      // setMockInitialValues so AsyncNotifier.build() runs without
      // platform code being registered.
      SharedPreferences.setMockInitialValues(const {});
    });

    test('clean prefs → empty state', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(simIdentityOverrideProvider.future);
      expect(s.active, isFalse);
      expect(s.current, isNull);
      expect(s.history, isEmpty);
    });

    test('generateAndApply pushes onto history and activates', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      // Wait for build() before mutating so the AsyncNotifier has data.
      await c.read(simIdentityOverrideProvider.future);
      // Pin random so the assertion below is reproducible.
      ctrl.generator = IccidImsiGenerator(random: Random(1));

      final fresh = await ctrl.generateAndApply(ChineseCarrierPreset.cmcc);

      final s = c.read(simIdentityOverrideProvider).requireValue;
      expect(s.active, isTrue);
      expect(s.current?.iccid, fresh.iccid);
      expect(s.history, hasLength(1));
      expect(s.history.first.iccid, fresh.iccid);
      expect(isLuhnValid(fresh.iccid), isTrue);
    });

    test(
      'history caps at SimIdentityOverrideController.historyLimit',
      () async {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final ctrl = c.read(simIdentityOverrideProvider.notifier);
        await c.read(simIdentityOverrideProvider.future);
        ctrl.generator = IccidImsiGenerator(random: Random(2));

        for (
          var i = 0;
          i < SimIdentityOverrideController.historyLimit + 5;
          i++
        ) {
          await ctrl.generateAndApply(ChineseCarrierPreset.cucc);
        }

        final s = c.read(simIdentityOverrideProvider).requireValue;
        expect(
          s.history,
          hasLength(SimIdentityOverrideController.historyLimit),
        );
      },
    );

    test('deactivate keeps current + history; reset clears both', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      await c.read(simIdentityOverrideProvider.future);
      ctrl.generator = IccidImsiGenerator(random: Random(3));
      await ctrl.generateAndApply(ChineseCarrierPreset.ctcc);

      await ctrl.deactivate();
      var s = c.read(simIdentityOverrideProvider).requireValue;
      expect(s.active, isFalse);
      expect(s.current, isNotNull, reason: 'deactivate must preserve current');
      expect(s.history, hasLength(1));

      await ctrl.reset();
      s = c.read(simIdentityOverrideProvider).requireValue;
      expect(s.active, isFalse);
      expect(s.current, isNull);
      expect(s.history, isEmpty);
    });

    test('applyFromHistory activates without changing history order', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      await c.read(simIdentityOverrideProvider.future);
      ctrl.generator = IccidImsiGenerator(random: Random(4));
      await ctrl.generateAndApply(ChineseCarrierPreset.cmcc);
      await ctrl.generateAndApply(ChineseCarrierPreset.cucc); // newest
      await ctrl.deactivate();

      final before = c.read(simIdentityOverrideProvider).requireValue;
      final older = before.history.last; // cmcc generation
      await ctrl.applyFromHistory(older);

      final after = c.read(simIdentityOverrideProvider).requireValue;
      expect(after.active, isTrue);
      expect(after.current?.iccid, older.iccid);
      // History order untouched — applyFromHistory doesn't re-rank.
      expect(
        after.history.map((g) => g.iccid).toList(),
        before.history.map((g) => g.iccid).toList(),
      );
    });

    test('state survives provider re-build (persistence round-trip)', () async {
      // Build #1: generate one, then dispose.
      var c = ProviderContainer();
      final ctrl = c.read(simIdentityOverrideProvider.notifier);
      await c.read(simIdentityOverrideProvider.future);
      ctrl.generator = IccidImsiGenerator(random: Random(5));
      final fresh = await ctrl.generateAndApply(ChineseCarrierPreset.cmccLte);
      c.dispose();

      // Build #2: fresh container; build() must hydrate from prefs.
      c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(simIdentityOverrideProvider.future);
      expect(s.active, isTrue);
      expect(s.current?.iccid, fresh.iccid);
      expect(s.history.first.iccid, fresh.iccid);
    });

    test('decode tolerates legacy / malformed payload', () async {
      SharedPreferences.setMockInitialValues(const {
        'sim_identity_override.v1': '{not valid json',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(simIdentityOverrideProvider.future);
      expect(s, SimIdentityOverride.empty);
    });

    test('active without a current can\'t happen post-decode', () async {
      // Persisted "active: true" + "current: null" is contradictory —
      // the decoder downgrades to inactive so the UI never has to
      // handle the impossible state.
      SharedPreferences.setMockInitialValues(const {
        'sim_identity_override.v1':
            '{"active": true, "current": null, "history": []}',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(simIdentityOverrideProvider.future);
      expect(s.active, isFalse);
      expect(s.current, isNull);
    });
  });
}
