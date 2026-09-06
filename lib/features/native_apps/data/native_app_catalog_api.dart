import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../home/state/installed_apps_provider.dart';
import '../../mini_apps/packaging/pkg_native_bridge.dart';
import '../domain/native_app.dart';

final nativeAppCatalogApiProvider = Provider<NativeAppCatalogApi>(
  (ref) => NativeAppCatalogApi(bridge: ref.watch(pkgBridgeProvider)),
);

/// Local installed-package library. No account or catalog server.
class NativeAppCatalogApi {
  NativeAppCatalogApi({required PkgNativeBridge bridge}) : _bridge = bridge;
  final PkgNativeBridge _bridge;
  Future<List<NativeApp>> fetchCatalog() async => [
    for (final p in await _bridge.list())
      NativeApp(
        packageId: p.packageName,
        displayName: {'en': p.label},
        description: const {},
        latestVersionCode: p.versionCode,
        latestVersionName: p.versionName,
        installedVersionCode: p.versionCode,
      ),
  ];
}
