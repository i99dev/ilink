/// DiLink 5.0 adapter — first-generation BYD framework.
///
/// Notable differences from 5.1:
/// - Push dispatch reaches both shell-UID and Application contexts
///   (5.1 narrowed to App-context only).
/// - Some `BYDAutoFeatureIds` constants renumbered between 5.0 and
///   5.1 — we ship a `dilink_5_0/` action-table variant.
/// - No cluster-pixel signing gate (that landed with the Leopard 8
///   8.x ROMs).
library;

import 'byd_dilink_adapter.dart';

class BydDilink50Adapter extends BydDilinkAdapter {
  const BydDilink50Adapter();

  @override
  DilinkVersion get version => DilinkVersion.dilink_5_0;

  @override
  String? get assetBundleDir => 'dilink_5_0';

  @override
  bool get pushRequiresAppContext => false; // 5.0 dispatches to both

  @override
  bool get clusterPixelSignatureGated => false;
}
