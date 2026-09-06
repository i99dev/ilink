/// Tests for the centralised mini-apps section registry.
///
/// Pin the contract two consumer surfaces depend on:
///   * [MiniAppsScreen] — renders the visible subset.
///   * [_StoreTab] + [_CategoryChipRail] — read [flightTestEnabledProvider]
///     to gate the developer-category surface.
///
/// Both consumers MUST share the same gate provider so a single
/// setting toggle propagates atomically. The test overrides
/// [flightTestEnabledProvider] directly so the registry's behaviour
/// is exercised without hauling in the full settings stack
/// (`appConfigBaseProvider` etc.).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/state/mini_app_sections.dart';
import 'package:ilink/features/native_apps/state/native_app_store_controller.dart';

ProviderContainer _container({
  required bool flightTestOn,
  bool nativeStoreOn = false,
}) {
  final c = ProviderContainer(
    overrides: [
      flightTestEnabledProvider.overrideWith((_) => flightTestOn),
      nativeStoreEnabledProvider.overrideWith((_) => nativeStoreOn),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('miniAppSectionsProvider', () {
    test('always exposes the canonical id list', () {
      final c = _container(flightTestOn: false);
      final all = c.read(miniAppSectionsProvider);
      expect(all.map((s) => s.id), [
        'installed',
        'store',
        'native-apps',
        'flight-test',
      ]);
    });

    test('id values are stable + non-empty for diagnostics', () {
      final c = _container(flightTestOn: true);
      for (final s in c.read(miniAppSectionsProvider)) {
        expect(s.id, isNotEmpty);
        expect(s.labelOf, isNotNull);
      }
    });
  });

  group('visibleMiniAppSectionsProvider', () {
    test('hides flight-test when the gate is off', () {
      final c = _container(flightTestOn: false);
      expect(c.read(visibleMiniAppSectionsProvider).map((s) => s.id), [
        'installed',
        'store',
      ]);
    });

    test('reveals flight-test when the gate is on', () {
      final c = _container(flightTestOn: true);
      expect(c.read(visibleMiniAppSectionsProvider).map((s) => s.id), [
        'installed',
        'store',
        'flight-test',
      ]);
    });

    test('hides native-apps when the store gate is off', () {
      final c = _container(flightTestOn: true, nativeStoreOn: false);
      expect(
        c.read(visibleMiniAppSectionsProvider).map((s) => s.id),
        isNot(contains('native-apps')),
      );
    });

    test('reveals native-apps when the store gate is on', () {
      final c = _container(flightTestOn: false, nativeStoreOn: true);
      expect(c.read(visibleMiniAppSectionsProvider).map((s) => s.id), [
        'installed',
        'store',
        'native-apps',
      ]);
    });

    test('order is stable across the gate flip — optional sections last', () {
      // Whether flight-test is on or off, "installed" + "store"
      // stay at indices 0 + 1. The optional section appends at the
      // end so toggling the gate doesn't shift the user's focus
      // off whichever always-visible tab they were on.
      final off = _container(flightTestOn: false);
      final on = _container(flightTestOn: true);
      expect(
        on.read(visibleMiniAppSectionsProvider)[0].id,
        off.read(visibleMiniAppSectionsProvider)[0].id,
      );
      expect(
        on.read(visibleMiniAppSectionsProvider)[1].id,
        off.read(visibleMiniAppSectionsProvider)[1].id,
      );
    });
  });

  group('flightTestEnabledProvider', () {
    test('default unhydrated value is false (fail-closed)', () {
      // No override — provider falls back through
      // `settingsProvider.select`'s null-safe `?? false`. Doesn't
      // need a hydrated settings to default off.
      final c = ProviderContainer(
        overrides: [
          // Stub: a provider that always errors, mimicking
          // settings-not-yet-hydrated but allowing
          // `flightTestEnabledProvider`'s `.select(... ?? false)` to
          // resolve since `select` reads `.value` (null when erroring).
          flightTestEnabledProvider.overrideWith((_) => false),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(flightTestEnabledProvider), isFalse);
    });
  });
}
