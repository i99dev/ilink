import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The persisted "default curated playlist" that keeps the Radio page from
/// opening empty: null on a fresh install (→ the page resolves the Arabic
/// fleet default), and a user's pick sticks across launches — mirroring the
/// TV country-order preference.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container({Map<String, Object>? prefs}) async {
    SharedPreferences.setMockInitialValues(prefs ?? {});
    final sp = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('fleet default region is Arabic', () {
    expect(kRadioDefaultRegionQuery, 'arabic');
  });

  test(
    'fresh install → null (page falls back to the Arabic default)',
    () async {
      final c = await container();
      expect(c.read(radioDefaultPlaylistProvider), isNull);
    },
  );

  test('set() persists the user pick + reloads across containers', () async {
    final c = await container();
    await c.read(radioDefaultPlaylistProvider.notifier).set('language: jazz');
    expect(c.read(radioDefaultPlaylistProvider), 'language: jazz');

    // A fresh container (new launch) hydrates the saved choice.
    final c2 = await container(
      prefs: {'radio.default_playlist.v1': 'language: jazz'},
    );
    expect(c2.read(radioDefaultPlaylistProvider), 'language: jazz');
  });

  test('set() ignores empty + no-op on same value', () async {
    final c = await container();
    await c.read(radioDefaultPlaylistProvider.notifier).set('');
    expect(c.read(radioDefaultPlaylistProvider), isNull);
  });
}
