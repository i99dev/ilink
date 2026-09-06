import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/location/location_service.dart';
import '../data/permission_service.dart';

/// Single swap point — `kIsWeb` picks the no-op implementation so
/// onboarding renders on web without trying to invoke
/// permission_handler (which throws on the web platform channel).
final permissionServiceProvider = Provider<PermissionService>((ref) {
  if (kIsWeb) return const WebNoopPermissionService();
  return NativePermissionService(ref.watch(locationServiceProvider));
});
