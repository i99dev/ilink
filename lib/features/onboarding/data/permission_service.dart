import 'package:permission_handler/permission_handler.dart';

import '../../../platform/location/location_service.dart';
import '../domain/permission_kind.dart';

/// Boundary for actually triggering OS-level permission dialogs.
///
/// Two implementations:
///   - [NativePermissionService] runs on Android/iOS and routes each
///     [PermissionKind] to the right native channel (geolocator for
///     location, permission_handler for the rest).
///   - [WebNoopPermissionService] returns `unavailable` for everything;
///     the browser prompts on first use of each Web API anyway.
///
/// Pick one via `permission_service_provider.dart` based on `kIsWeb`.
abstract class PermissionService {
  Future<PermissionRequestResult> request(PermissionKind kind);
}

class NativePermissionService implements PermissionService {
  const NativePermissionService(this._location);

  final LocationService _location;

  @override
  Future<PermissionRequestResult> request(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.location:
        return _requestLocation();
      case PermissionKind.microphone:
        return _statusToResult(await Permission.microphone.request());
      case PermissionKind.notifications:
        return _statusToResult(await Permission.notification.request());
    }
  }

  /// Routes through [LocationService] — single owner of every Geolocator
  /// interaction in this build. The service distinguishes
  /// whileInUse / always / deniedForever / unableToDetermine and folds
  /// them into the three outcomes onboarding cares about.
  Future<PermissionRequestResult> _requestLocation() async {
    final outcome = await _location.requestPermission();
    switch (outcome) {
      case LocationPermissionOutcome.granted:
        return PermissionRequestResult.granted;
      case LocationPermissionOutcome.denied:
        return PermissionRequestResult.denied;
      case LocationPermissionOutcome.unavailable:
        return PermissionRequestResult.unavailable;
    }
  }

  static PermissionRequestResult _statusToResult(PermissionStatus s) {
    if (s.isGranted || s.isLimited || s.isProvisional) {
      return PermissionRequestResult.granted;
    }
    if (s.isPermanentlyDenied || s.isDenied || s.isRestricted) {
      return PermissionRequestResult.denied;
    }
    return PermissionRequestResult.unavailable;
  }
}

class WebNoopPermissionService implements PermissionService {
  const WebNoopPermissionService();

  @override
  Future<PermissionRequestResult> request(PermissionKind kind) async {
    // Browser handles per-API; nothing to ask about here. The
    // onboarding screen shows a banner explaining this so the user
    // understands why the toggle ran but no dialog appeared.
    return PermissionRequestResult.unavailable;
  }
}
