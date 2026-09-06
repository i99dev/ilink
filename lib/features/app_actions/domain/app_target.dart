import 'package:flutter/foundation.dart';

/// Sealed type for "what app are we managing".
///
/// Native and mini-apps share the long-press → unified sheet flow but
/// have different action sets:
///   * Native: full 7 actions (pm/am/dumpsys-driven).
///   * Mini-app: subset (no pm uninstall, no clear-data via shell —
///     the mini-app catalog handles uninstall via API).
///
/// Eligibility logic in the action registry inspects the runtime
/// type to decide which actions render.
@immutable
sealed class AppTarget {
  const AppTarget({required this.label, this.iconBytes});

  /// User-visible name. For native apps this is the loaded application
  /// label; for mini-apps it's the manifest's localised name.
  final String label;

  /// Optional rasterised icon. Null when the icon is loaded lazily by
  /// the host (e.g. via `installed_apps_strip` cache).
  final Uint8List? iconBytes;
}

/// A native Android package on the head unit.
class NativeAppTarget extends AppTarget {
  const NativeAppTarget({
    required this.packageName,
    required super.label,
    super.iconBytes,
  });

  /// Unique key for caching, analytics, and shell commands.
  final String packageName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeAppTarget && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;
}

/// An ilink mini-app from the catalog.
class MiniAppTarget extends AppTarget {
  const MiniAppTarget({
    required this.appId,
    required super.label,
    super.iconBytes,
  });

  /// e.g. `weather-ahead` — distinct namespace from package names.
  final String appId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MiniAppTarget && other.appId == appId;

  @override
  int get hashCode => appId.hashCode;
}
