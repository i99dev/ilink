/// DiLink 5.1 adapter — the default for everything shipped 2024H2
/// onward (Han L4, Tang L4, Leopard 5, Leopard 8, Leopard 9).
///
/// Notable behaviours:
/// - Push dispatch reaches Application-context instances only.
///   The shell-UID daemon constructs `BydPushDevice` but never
///   receives `onPostEvent` callbacks — verified empirically on
///   Leopard 8 (May 2026). The in-app `InAppPushManager` is the
///   sole reliable push source.
/// - `BYDAutoFeatureIds` constant pool stabilised; `BydAutoFeatureIdsCatalog`
///   reflects ~21k entries (bare + prefixed names).
/// - No cluster-pixel signing gate.
library;

import 'byd_dilink_adapter.dart';

class BydDilink51Adapter extends BydDilinkAdapter {
  const BydDilink51Adapter();

  @override
  DilinkVersion get version => DilinkVersion.dilink_5_1;

  /// `null` = use the shared default asset (`assets/car_table.pb.enc`).
  /// 5.1 is the dominant ROM today; the shared asset matches it.
  /// When a versioned variant ships, change this to `'dilink_5_1'`.
  @override
  String? get assetBundleDir => null;

  @override
  bool get pushRequiresAppContext => true;

  @override
  bool get clusterPixelSignatureGated => false;
}
