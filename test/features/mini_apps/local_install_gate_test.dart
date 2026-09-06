import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_track.dart';
import 'package:ilink/features/mini_apps/state/mini_app_install_gate.dart';
import 'package:ilink/features/mini_apps/state/mini_app_providers.dart';

class _Catalog extends MiniAppCatalogController {
  int installs = 0;
  @override
  Future<List<MiniApp>> build() async => [
    const MiniApp(
      id: 'local',
      name: {'en': 'Local'},
      description: {},
      icon: '',
      url: '',
      version: '1.0.0',
      minHostVersion: '0.0.0',
      category: 'other',
      bundleUrl: '',
      bundleSha256: '',
      track: MiniAppTrack.beta,
    ),
  ];
  @override
  Future<void> install(String id) async {
    installs++;
  }
}

void main() {
  test('local beta installation requires no account or subscription', () async {
    final catalog = _Catalog();
    final c = ProviderContainer(
      overrides: [miniAppCatalogProvider.overrideWith(() => catalog)],
    );
    addTearDown(c.dispose);
    await c.read(miniAppCatalogProvider.future);
    final result = await c
        .read(miniAppInstallGateProvider)
        .install(caller: StoreTabInstaller.instance, appId: 'local');
    expect(result, isA<InstallOk>());
    expect(catalog.installs, 1);
  });
  test('unknown app fails before mutation', () async {
    final catalog = _Catalog();
    final c = ProviderContainer(
      overrides: [miniAppCatalogProvider.overrideWith(() => catalog)],
    );
    addTearDown(c.dispose);
    await c.read(miniAppCatalogProvider.future);
    expect(
      await c
          .read(miniAppInstallGateProvider)
          .install(caller: StoreTabInstaller.instance, appId: 'unknown'),
      isA<InstallUnknownApp>(),
    );
    expect(catalog.installs, 0);
  });
}
