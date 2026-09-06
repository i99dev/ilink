import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/app_actions/domain/app_action.dart';
import 'package:ilink/features/app_actions/domain/app_target.dart';
import 'package:ilink/features/app_actions/state/app_action_controller.dart';
import 'package:ilink/features/home/state/installed_apps_provider.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_native_bridge.dart';
import 'package:ilink/features/mini_apps/packaging/pkg_snapshot.dart';
import 'package:ilink/features/native_apps/data/native_app_catalog_api.dart';
import 'package:ilink/features/native_apps/domain/native_app.dart';
import 'package:ilink/features/native_apps/state/native_app_store_controller.dart';

class _FakeCatalogApi implements NativeAppCatalogApi {
  _FakeCatalogApi(this.apps);
  List<NativeApp> apps;
  @override
  Future<List<NativeApp>> fetchCatalog() async => apps;
}

class _FakeBridge implements PkgNativeBridge {
  _FakeBridge(this.installed);

  /// packageName → versionCode
  final Map<String, int> installed;

  @override
  Future<List<PackageSnapshot>> list({bool includeSystem = false}) async => [
    for (final e in installed.entries)
      PackageSnapshot(
        packageName: e.key,
        label: e.key,
        versionName: '${e.value}.0',
        versionCode: e.value,
        isSystem: false,
      ),
  ];

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName} not faked');
}

class _FakeActionController extends AppActionController {
  _FakeActionController(this.outcome);
  final AppActionOutcome outcome;
  @override
  void build() {}
  @override
  Future<AppActionOutcome> run({
    required AppActionKind kind,
    required AppTarget target,
    int? displayId,
    int? taskId,
  }) async => outcome;
}

NativeApp _app(String pkg, int latest) => NativeApp(
  packageId: pkg,
  displayName: {'en': pkg},
  description: const {},
  latestVersionCode: latest,
  latestVersionName: '$latest.0',
);

ProviderContainer _container({
  required List<NativeApp> catalog,
  required Map<String, int> installed,
}) {
  return ProviderContainer(
    overrides: [
      nativeAppCatalogApiProvider.overrideWithValue(_FakeCatalogApi(catalog)),
      pkgBridgeProvider.overrideWithValue(_FakeBridge(installed)),
    ],
  );
}

void main() {
  // The controller's build() registers an app-resume listener via
  // AppLifecycleBus, which calls WidgetsBinding.instance.addObserver.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativeApp model', () {
    test('fromJson parses locale maps + version + screenshots', () {
      final app = NativeApp.fromJson({
        'packageId': 'com.acme.dash',
        'displayName': {'en': 'Dash', 'ar': 'داش'},
        'description': {'en': 'A dashcam'},
        'latestVersionCode': 7,
        'latestVersionName': '1.2.0',
        'category': 'tools',
        'iconUrl': 'http://cdn/icon.svg',
        'screenshots': ['http://cdn/1.png', 42, 'http://cdn/2.png'],
      });
      expect(app.packageId, 'com.acme.dash');
      expect(app.localizedName('ar'), 'داش');
      expect(app.localizedName('ru'), 'Dash'); // falls back to en
      expect(app.latestVersionCode, 7);
      expect(app.screenshots, ['http://cdn/1.png', 'http://cdn/2.png']);
    });

    test('localizedName derives a friendly title when no copy', () {
      const snake = NativeApp(
        packageId: 'com.acme.dash_cam',
        displayName: {},
        description: {},
        latestVersionCode: 1,
        latestVersionName: '1',
      );
      expect(snake.localizedName('en'), 'Dash Cam');

      const camel = NativeApp(
        packageId: 'com.didjdk.adbHelper',
        displayName: {},
        description: {},
        latestVersionCode: 1,
        latestVersionName: '1',
      );
      expect(camel.localizedName('en'), 'Adb Helper');
    });

    test('install-state getters derive from installedVersionCode', () {
      final base = _app('p', 5);
      expect(base.isInstalled, isFalse);
      expect(base.hasUpdate, isFalse);

      final current = base.withInstalledVersion(5);
      expect(current.isInstalled, isTrue);
      expect(current.hasUpdate, isFalse);

      final stale = base.withInstalledVersion(4);
      expect(stale.isInstalled, isTrue);
      expect(stale.hasUpdate, isTrue);
    });
  });

  group('NativeAppStoreController.build (catalog ⨉ installed merge)', () {
    test('stamps installed versionCode onto matching rows', () async {
      final container = _container(
        catalog: [_app('a', 5), _app('b', 3)],
        installed: {'a': 4, 'c': 9},
      );
      addTearDown(container.dispose);

      final apps = await container.read(nativeAppStoreProvider.future);
      final a = apps.firstWhere((x) => x.packageId == 'a');
      final b = apps.firstWhere((x) => x.packageId == 'b');

      expect(a.installedVersionCode, 4);
      expect(a.hasUpdate, isTrue); // 5 > 4
      expect(b.installedVersionCode, isNull);
      expect(b.isInstalled, isFalse);
    });

    test(
      'refreshInstalledState re-stamps without re-fetching catalog',
      () async {
        final installed = <String, int>{};
        final container = ProviderContainer(
          overrides: [
            nativeAppCatalogApiProvider.overrideWithValue(
              _FakeCatalogApi([_app('a', 5)]),
            ),
            pkgBridgeProvider.overrideWithValue(_FakeBridge(installed)),
          ],
        );
        addTearDown(container.dispose);

        var apps = await container.read(nativeAppStoreProvider.future);
        expect(apps.single.isInstalled, isFalse);

        // Simulate the package appearing after the consent install, then the
        // app-resume re-stamp.
        installed['a'] = 5;
        await container
            .read(nativeAppStoreProvider.notifier)
            .refreshInstalledState();

        apps = container.read(nativeAppStoreProvider).value!;
        expect(apps.single.installedVersionCode, 5);
        expect(apps.single.isInstalled, isTrue);
      },
    );
  });

  group('NativeAppStoreController.uninstall', () {
    Future<NativeStoreInstallResult> run(AppActionOutcome outcome) async {
      final container = ProviderContainer(
        overrides: [
          nativeAppCatalogApiProvider.overrideWithValue(
            _FakeCatalogApi(const []),
          ),
          pkgBridgeProvider.overrideWithValue(_FakeBridge({'p': 9})),
          appActionControllerProvider.overrideWith(
            () => _FakeActionController(outcome),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container
          .read(nativeAppStoreProvider.notifier)
          .uninstall(_app('p', 9), label: 'P');
    }

    test('ok → uninstalled', () async {
      expect(
        (await run(AppActionOutcome.ok)).kind,
        NativeStoreInstallKind.uninstalled,
      );
    });

    test('failed → uninstallFailed', () async {
      expect(
        (await run(AppActionOutcome.failed)).kind,
        NativeStoreInstallKind.uninstallFailed,
      );
    });
  });
}
