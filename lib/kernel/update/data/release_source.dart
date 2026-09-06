import '../models/release_manifest.dart';

/// Core update logic only depends on this source, not a distribution backend.
abstract interface class ReleaseSource {
  Future<ReleaseManifest?> latest({required int installedVersionCode});
}
