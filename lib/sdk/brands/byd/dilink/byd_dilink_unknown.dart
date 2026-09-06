/// Fallback adapter — used when version detection fails (test
/// runner, non-BYD device, unsupported ROM, reflection error).
///
/// Conservative policy: behave like DiLink 5.1 (the dominant
/// shipping ROM) so the rest of the SDK keeps working under best-
/// guess assumptions. No cluster-pixel writes attempted (treats
/// them as gated, the safe bet).
library;

import 'byd_dilink_adapter.dart';

class BydDilinkUnknownAdapter extends BydDilinkAdapter {
  const BydDilinkUnknownAdapter();

  @override
  DilinkVersion get version => DilinkVersion.unknown;

  @override
  String? get assetBundleDir => null;

  @override
  bool get pushRequiresAppContext => true;

  @override
  bool get clusterPixelSignatureGated => true;
}
