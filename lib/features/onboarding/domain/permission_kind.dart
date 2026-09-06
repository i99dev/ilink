import 'package:flutter/material.dart';

/// Permissions surfaced to the user on the first-launch onboarding.
///
/// Bluetooth is intentionally excluded — the head unit handles BT audio
/// natively, the Dart layer never calls BT APIs, and asking only
/// confuses users about why we'd need it.
enum PermissionKind { location, microphone, notifications }

/// Result of a single `request()` call. Surfaces in the per-tile
/// status pill so the user can see which permissions ended up
/// approved / denied without needing to open OS settings.
enum PermissionRequestResult {
  /// Not yet attempted.
  idle,

  /// User granted (or already granted before).
  granted,

  /// User denied at the OS dialog.
  denied,

  /// User toggled this off in the onboarding screen — no request was
  /// made. Distinguished from `denied` so the status pill can be
  /// honest about what happened.
  skipped,

  /// Platform doesn't expose this permission for runtime request
  /// (e.g., web — the browser handles it per-feature).
  unavailable,
}

extension PermissionKindUi on PermissionKind {
  /// Material icon used in the onboarding tile.
  IconData get icon => switch (this) {
    PermissionKind.location => Icons.location_on_outlined,
    PermissionKind.microphone => Icons.mic_none_outlined,
    PermissionKind.notifications => Icons.notifications_none_outlined,
  };
}
