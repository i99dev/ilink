import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/lifecycle/app_lifecycle_bus.dart';
import '../../mini_apps/packaging/pkg_native_bridge.dart';
import '../../mini_apps/packaging/pkg_snapshot.dart';

final pkgBridgeProvider = Provider<PkgNativeBridge>(
  (ref) => PlatformPkgNativeBridge(),
);

/// Our own package — hidden from every surface that consumes
/// [installedAppsProvider] (apps grid, drag chips, display drop
/// targets). Launching ilink from within ilink is meaningless,
/// and seeing our own icon as a draggable chip on the Displays
/// widget is just visual noise.
const _kHostPackage = 'com.i99dev.ilink';

final installedAppsProvider = FutureProvider.autoDispose<List<PackageSnapshot>>(
  (ref) async {
    // Re-query when the app foregrounds — e.g. the user uninstalled a
    // package from the OS settings (or another surface) and returned. The
    // grid reads the pkg.list bridge (not a Riverpod provider), so nothing
    // else would refresh it without reopening ilink.
    final bus = ref.read(appLifecycleBusProvider);
    final sub = bus.onResumed.listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);

    final bridge = ref.watch(pkgBridgeProvider);
    final apps = await bridge.list(includeSystem: false);
    final filtered = apps.where((a) => a.packageName != _kHostPackage);
    final sorted = filtered.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return sorted;
  },
);
