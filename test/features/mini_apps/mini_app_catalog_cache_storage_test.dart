import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/catalog_endpoint.dart';
import 'package:ilink/features/mini_apps/data/mini_app_catalog_cache_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MiniAppCatalogCacheStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = MiniAppCatalogCacheStorage(SharedPreferences.getInstance);
  });

  test('read returns null on empty cache', () async {
    expect(await storage.read(endpoint: CatalogEndpoint.public), isNull);
  });

  test('write + read round-trip preserves rows and ETag', () async {
    await storage.write(
      const [
        {
          'id': 'demo-app',
          'name': {'en': 'Demo'},
        },
        {'id': 'example-app', 'icon': 'https://cdn/icon.png'},
      ],
      etag: 'W/"123-2"',
      endpoint: CatalogEndpoint.public,
    );
    final entry = await storage.read(endpoint: CatalogEndpoint.public);
    expect(entry, isNotNull);
    expect(entry!.etag, 'W/"123-2"');
    expect(entry.rawApps, hasLength(2));
    expect(entry.rawApps[0]['id'], 'demo-app');
    expect(entry.rawApps[1]['icon'], 'https://cdn/icon.png');
  });

  test('write tolerates a null ETag (server stripped header)', () async {
    await storage.write(const [
      {'id': 'a'},
    ], endpoint: CatalogEndpoint.public);
    final entry = await storage.read(endpoint: CatalogEndpoint.public);
    expect(entry, isNotNull);
    expect(entry!.etag, isNull);
    expect(entry.rawApps, hasLength(1));
  });

  test('read returns null on corrupt JSON', () async {
    SharedPreferences.setMockInitialValues({'mini_apps.catalog': 'not-json'});
    storage = MiniAppCatalogCacheStorage(SharedPreferences.getInstance);
    expect(await storage.read(endpoint: CatalogEndpoint.public), isNull);
  });

  test('read drops non-map rows but keeps the rest', () async {
    // A future schema change shouldn't poison every row — keep what
    // parses, drop what doesn't.
    SharedPreferences.setMockInitialValues({
      'mini_apps.catalog':
          '{"at": 1700000000000, "etag": null, "v": [{"id": "good"}, "junk", {"id": "also-good"}]}',
    });
    storage = MiniAppCatalogCacheStorage(SharedPreferences.getInstance);
    final entry = await storage.read(endpoint: CatalogEndpoint.public);
    expect(entry, isNotNull);
    expect(entry!.rawApps, hasLength(2));
    expect(entry.rawApps.map((r) => r['id']), ['good', 'also-good']);
  });

  test('clear removes both endpoint caches', () async {
    // Seed both keys to confirm clear() iterates all CatalogEndpoint values.
    await storage.write(
      const [
        {'id': 'x'},
      ],
      etag: 'W/"1-1"',
      endpoint: CatalogEndpoint.public,
    );
    await storage.write(
      const [
        {'id': 'y'},
      ],
      etag: 'W/"1-2"',
      endpoint: CatalogEndpoint.me,
    );
    await storage.clear();
    expect(await storage.read(endpoint: CatalogEndpoint.public), isNull);
    expect(await storage.read(endpoint: CatalogEndpoint.me), isNull);
  });

  test('cachedAt reflects write time', () async {
    final before = DateTime.now();
    await storage.write(const [
      {'id': 'x'},
    ], endpoint: CatalogEndpoint.public);
    final after = DateTime.now();
    final entry = await storage.read(endpoint: CatalogEndpoint.public);
    expect(entry, isNotNull);
    // Allow a generous window — clock-of-test resolution is loose.
    expect(
      entry!.cachedAt.isAfter(before.subtract(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      entry.cachedAt.isBefore(after.add(const Duration(seconds: 1))),
      isTrue,
    );
  });
}
