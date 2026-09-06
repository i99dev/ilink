/// Single registration point for every native-capability family on
/// this host build. Adding a new family is one more `..register(...)`
/// call inside [setupBridgeRegistry]. The [BridgeFamilyRegistry] is
/// process-static so the registry has every family before the first
/// WebView opens.
///
/// **Car-data families** (climate, system, media, connectivity,
/// vehicle.diagnostics, vehicle.environment, navigation, location)
/// are gone. They were per-family `ReadOnlyDataFamily` wrappers over
/// snapshot views that no longer exist. Every car-data read /
/// subscribe now goes through `car.*` on [CarBridgeService] — single
/// chokepoint, one fan-out, one throttle, name-keyed access. See
/// `lib/features/mini_apps/bridge/car_bridge_service.dart`.
///
/// What remains here is the **native-capability** surface — display,
/// surface, cursor, gesture, pkg, boot. These are privileged ops the
/// host exposes for cluster-targeting / package launching / boot-
/// position pinning. They still register as [MiniAppFamily] entries
/// because their handler shape is operation-keyed, not data-keyed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin_mini_apps/state/admin_dispatcher_provider.dart';
import '../data/installed_mini_app_store.dart';
import '../lifecycle/boot_family.dart';
import '../lifecycle/boot_store.dart';
import '../packaging/pkg_family.dart';
import '../runtime/cursor_family.dart';
import '../runtime/display_family.dart';
import '../runtime/gesture_family.dart';
import '../runtime/surface_family.dart';
import '../state/family_executor_provider.dart';

/// Register every native-capability family with the process-wide
/// [BridgeFamilyRegistry]. Safe to call exactly once at boot. Captures
/// `ref` for closures that need to resolve providers lazily — e.g. the
/// surface family's bundle URI resolver and the boot family's store
/// resolver, which depend on the admin DB opening asynchronously.
void setupBridgeRegistry(WidgetRef ref) {
  ref.read(bridgeFamilyRegistryProvider)
    ..register(DisplayFamily())
    ..register(
      SurfaceFamily(
        bundleUriResolver: (appId) async {
          final store = ref.read(installedMiniAppStoreProvider);
          return store.indexHtmlPath(appId);
        },
      ),
    )
    // Input injection + IVI-side cursor for "remote control of
    // cluster" mini-apps.
    ..register(GestureFamily())
    ..register(CursorFamily())
    // Package + boot families.
    ..register(PkgFamily())
    ..register(
      BootFamily(
        // Lazy-resolve the BootStore so the family registers
        // synchronously at host bootstrap (the admin DB opens
        // asynchronously via [adminDatabaseProvider]). The
        // underlying DB is cached by the provider, so the
        // first await materialises the store and subsequent
        // calls reuse it.
        storeResolver: () async {
          final db = await ref.read(adminDatabaseProvider.future);
          return BootStore(db);
        },
      ),
    );
}
