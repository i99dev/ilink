/// DiLink 8.x adapter — Leopard 8 / Yangwang ROMs.
///
/// Notable behaviours:
/// - Mostly behaves like 5.1 (push is App-context only).
/// - Cluster pixel writes are signature-gated by the framework —
///   the cluster panel refuses our `setInt` unless the calling APK
///   is signed by the OEM key. See memory: `leopard8 cluster signature
///   gate`. Consumers query [clusterPixelSignatureGated] before
///   attempting cluster writes and fall back to the dash overlay.
/// - Action table may diverge for the gated paths — when a
///   version-specific encrypted bundle is needed it ships under
///   `assets/byd/dilink_8_x/`.
library;

import 'byd_dilink_adapter.dart';

class BydDilink8XAdapter extends BydDilinkAdapter {
  const BydDilink8XAdapter();

  @override
  DilinkVersion get version => DilinkVersion.dilink_8_x;

  /// `null` until an 8.x-specific bundle ships. Falls back to the
  /// shared default. Flip to `'dilink_8_x'` when divergence requires.
  @override
  String? get assetBundleDir => null;

  @override
  bool get pushRequiresAppContext => true;

  @override
  bool get clusterPixelSignatureGated => true;
}
