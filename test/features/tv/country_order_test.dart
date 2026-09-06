import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tv/domain/country_order.dart';
import 'package:ilink/features/tv/domain/tv_catalog.dart';
import 'package:ilink/features/tv/providers.dart';
import 'package:ilink/kernel/storage/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

TvCatalogGroup _country(String code, String name, int count) => TvCatalogGroup(
  kind: 'country',
  key: code,
  name: name,
  count: count,
  path: 'channels/country/$code.json',
  flag: '',
);

// Catalogue order on purpose NOT alphabetical / not count-sorted, so each
// mode's assertion is unambiguous.
final _catalog = <TvCatalogGroup>[
  _country('ae', 'United Arab Emirates', 38),
  _country('us', 'United States', 500),
  _country('fr', 'France', 120),
];

void main() {
  group('applyCountryOrder', () {
    test('catalogDefault preserves catalogue order', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(mode: TvCountrySort.catalogDefault),
      );
      expect(r.map((c) => c.key), ['ae', 'us', 'fr']);
    });

    test('middleEast: regional codes lead, rest in catalogue order', () {
      final cat = [
        _country('us', 'United States', 500),
        _country('fr', 'France', 120),
        _country('sa', 'Saudi Arabia', 60),
        _country('ae', 'United Arab Emirates', 38),
      ];
      // empty == Middle-East default. 'ae' precedes 'sa' per the curated list;
      // non-regional us/fr keep catalogue order in the tail.
      final r = applyCountryOrder(cat, CountryOrderPref.empty);
      expect(r.map((c) => c.key), ['ae', 'sa', 'us', 'fr']);
    });

    test('middleEast is the fresh-install default mode', () {
      expect(CountryOrderPref.empty.mode, TvCountrySort.middleEast);
    });

    test('alpha sorts by display name', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(mode: TvCountrySort.alpha),
      );
      // France, United Arab Emirates, United States
      expect(r.map((c) => c.key), ['fr', 'ae', 'us']);
    });

    test('channelCount sorts by count desc, name tie-break', () {
      final withTie = [..._catalog, _country('eg', 'Egypt', 120)];
      final r = applyCountryOrder(
        withTie,
        const CountryOrderPref(mode: TvCountrySort.channelCount),
      );
      // us(500), then 120-tie resolved by name: Egypt before France, then ae(38)
      expect(r.map((c) => c.key), ['us', 'eg', 'fr', 'ae']);
    });

    test(
      'custom: listed codes lead in order; rest appended catalogue-order',
      () {
        final r = applyCountryOrder(
          _catalog,
          const CountryOrderPref(
            mode: TvCountrySort.custom,
            customOrder: ['fr', 'us'],
          ),
        );
        // fr, us (explicit) then ae (catalogue order, not in custom list yet)
        expect(r.map((c) => c.key), ['fr', 'us', 'ae']);
      },
    );

    test('custom: codes no longer in the catalogue are dropped', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(
          mode: TvCountrySort.custom,
          customOrder: ['zz', 'fr'], // 'zz' gone from catalogue
        ),
      );
      expect(r.map((c) => c.key), ['fr', 'ae', 'us']);
      expect(r.map((c) => c.key), isNot(contains('zz')));
    });

    test('hidden countries are filtered out (every mode)', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(hidden: {'us'}),
      );
      expect(r.map((c) => c.key), ['ae', 'fr']);
    });

    test('hiding everything is a no-op fail-safe (never empty)', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(hidden: {'ae', 'us', 'fr'}),
      );
      expect(r.map((c) => c.key), ['ae', 'us', 'fr']);
    });

    test('empty catalogue stays empty', () {
      expect(applyCountryOrder(const [], CountryOrderPref.empty), isEmpty);
    });

    test('result preserves catalogue identity (same objects)', () {
      final r = applyCountryOrder(
        _catalog,
        const CountryOrderPref(mode: TvCountrySort.alpha),
      );
      expect(r, everyElement(isIn(_catalog)));
    });
  });

  group('CountryOrderPref json + equality', () {
    test('round-trips through json', () {
      const pref = CountryOrderPref(
        mode: TvCountrySort.custom,
        customOrder: ['fr', 'ae'],
        hidden: {'us'},
      );
      final back = CountryOrderPref.fromJson(pref.toJson());
      expect(back, pref);
    });

    test(
      'tolerates a malformed / partial blob (falls back to the default)',
      () {
        final back = CountryOrderPref.fromJson({'mode': 'nonsense'});
        expect(back.mode, TvCountrySort.middleEast);
        expect(back.customOrder, isEmpty);
        expect(back.hidden, isEmpty);
      },
    );

    test('value equality distinguishes order', () {
      const a = CountryOrderPref(
        mode: TvCountrySort.custom,
        customOrder: ['a', 'b'],
      );
      const b = CountryOrderPref(
        mode: TvCountrySort.custom,
        customOrder: ['b', 'a'],
      );
      expect(a == b, isFalse);
    });
  });

  group('tvCountryOrderProvider + orderedCountriesProvider', () {
    Future<ProviderContainer> container({Map<String, Object>? prefs}) async {
      SharedPreferences.setMockInitialValues(prefs ?? {});
      final sp = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          tvCatalogIndexProvider.overrideWith(
            (ref) => Future.value(
              TvCatalogIndex(generatedAt: DateTime(2026), groups: _catalog),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      // Resolve the index so orderedCountriesProvider sees the countries.
      await c.read(tvCatalogIndexProvider.future);
      return c;
    }

    test('defaults to Middle East first', () async {
      final c = await container();
      expect(c.read(tvCountryOrderProvider).mode, TvCountrySort.middleEast);
      // _catalog leads with 'ae' (regional); us/fr follow in catalogue order.
      expect(c.read(orderedCountriesProvider).map((g) => g.key), [
        'ae',
        'us',
        'fr',
      ]);
    });

    test('setMode(alpha) reorders the resolved list', () async {
      final c = await container();
      await c
          .read(tvCountryOrderProvider.notifier)
          .setMode(TvCountrySort.alpha);
      expect(c.read(orderedCountriesProvider).map((g) => g.key), [
        'fr',
        'ae',
        'us',
      ]);
    });

    test('applyCustomOrder persists + switches to custom mode', () async {
      final c = await container();
      await c.read(tvCountryOrderProvider.notifier).applyCustomOrder([
        'us',
        'fr',
        'ae',
      ]);

      final pref = c.read(tvCountryOrderProvider);
      expect(pref.mode, TvCountrySort.custom);
      expect(c.read(orderedCountriesProvider).map((g) => g.key), [
        'us',
        'fr',
        'ae',
      ]);

      // Survives a fresh container reading the same SharedPreferences.
      final sp = await SharedPreferences.getInstance();
      final c2 = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          tvCatalogIndexProvider.overrideWith(
            (ref) => Future.value(
              TvCatalogIndex(generatedAt: DateTime(2026), groups: _catalog),
            ),
          ),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(tvCatalogIndexProvider.future);
      expect(c2.read(tvCountryOrderProvider).mode, TvCountrySort.custom);
      expect(c2.read(orderedCountriesProvider).map((g) => g.key), [
        'us',
        'fr',
        'ae',
      ]);
    });

    test('setHidden removes from the chip list; clearing restores', () async {
      final c = await container();
      final n = c.read(tvCountryOrderProvider.notifier);
      await n.setHidden('us', true);
      expect(c.read(orderedCountriesProvider).map((g) => g.key), ['ae', 'fr']);
      await n.setHidden('us', false);
      expect(c.read(orderedCountriesProvider).map((g) => g.key), [
        'ae',
        'us',
        'fr',
      ]);
    });

    test('reset returns to the empty default', () async {
      final c = await container();
      final n = c.read(tvCountryOrderProvider.notifier);
      await n.setMode(TvCountrySort.alpha);
      await n.setHidden('us', true);
      await n.reset();
      expect(c.read(tvCountryOrderProvider), CountryOrderPref.empty);
      expect(c.read(orderedCountriesProvider).map((g) => g.key), [
        'ae',
        'us',
        'fr',
      ]);
    });
  });
}
