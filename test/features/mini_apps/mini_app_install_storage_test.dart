import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/mini_app_install_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MiniAppInstallStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = MiniAppInstallStorage(SharedPreferences.getInstance);
  });

  test(
    'first install on empty storage does not throw on unmodifiable map',
    () async {
      // Regression: load() previously returned `const {}` on an empty
      // pref; install() then tried to mutate it and threw
      // `Unsupported operation: Cannot modify unmodifiable map` on
      // every user's first ever Install tap. The fix is to always
      // return a fresh mutable map from load().
      await storage.install('demo-app');
      expect(await storage.isInstalled('demo-app'), isTrue);
    },
  );

  test('install + uninstall round-trip', () async {
    await storage.install('demo-app');
    await storage.install('example-app');
    expect(
      (await storage.load()).keys,
      containsAll(['demo-app', 'example-app']),
    );

    await storage.uninstall('demo-app');
    final after = await storage.load();
    expect(after.containsKey('demo-app'), isFalse);
    expect(after.containsKey('example-app'), isTrue);
  });

  test(
    'install is idempotent — repeated calls do not bump timestamp',
    () async {
      await storage.install('demo-app');
      final firstAt = (await storage.load())['demo-app']?.installedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await storage.install('demo-app');
      final secondAt = (await storage.load())['demo-app']?.installedAt;
      expect(secondAt, firstAt);
    },
  );

  test('uninstall on missing id is a no-op', () async {
    await storage.uninstall('never-installed');
    expect(await storage.load(), isEmpty);
  });

  test('corrupt pref blob loads as empty without throwing', () async {
    SharedPreferences.setMockInitialValues({'mini_apps.installed': 'not-json'});
    storage = MiniAppInstallStorage(SharedPreferences.getInstance);
    expect(await storage.load(), isEmpty);
    // And install on top of corrupt data must still work.
    await storage.install('demo-app');
    expect(await storage.isInstalled('demo-app'), isTrue);
  });

  // ── Phase-9.2: cert hash persistence for privileged mini-apps ──

  test(
    'install with certHash persists it; certHashFor reads it back',
    () async {
      await storage.install('admin-app', certHash: 'a' * 64);
      expect(await storage.certHashFor('admin-app'), 'a' * 64);
      final rec = (await storage.load())['admin-app'];
      expect(rec?.certHash, 'a' * 64);
    },
  );

  test(
    'install without certHash leaves it null (regular mini-app path)',
    () async {
      await storage.install('regular-app');
      expect(await storage.certHashFor('regular-app'), isNull);
      final rec = (await storage.load())['regular-app'];
      expect(rec?.certHash, isNull);
    },
  );

  test('updateCertHash overwrites without bumping installedAt', () async {
    await storage.install('admin-app', certHash: 'a' * 64);
    final before = (await storage.load())['admin-app']!;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await storage.updateCertHash('admin-app', 'b' * 64);
    final after = (await storage.load())['admin-app']!;
    expect(after.certHash, 'b' * 64);
    expect(after.installedAt, before.installedAt);
  });

  test(
    'legacy v1 pref blob (no cert_hash field) decodes with certHash=null',
    () async {
      // Simulate a pref written by the pre-Phase-9.2 storage version.
      SharedPreferences.setMockInitialValues({
        'mini_apps.installed':
            '[{"id":"legacy-app","installed_at":"2026-04-01T00:00:00.000Z"}]',
      });
      storage = MiniAppInstallStorage(SharedPreferences.getInstance);
      final loaded = await storage.load();
      expect(loaded['legacy-app']?.certHash, isNull);
      expect(loaded['legacy-app']?.installedAt.year, 2026);
    },
  );

  test('loadTimestamps drops the cert dimension for legacy callers', () async {
    await storage.install('a', certHash: 'a' * 64);
    await storage.install('b');
    final ts = await storage.loadTimestamps();
    expect(ts.keys, containsAll(['a', 'b']));
    // Plain Map<String, DateTime>; no record wrapping.
    expect(ts['a'], isA<DateTime>());
  });
}
