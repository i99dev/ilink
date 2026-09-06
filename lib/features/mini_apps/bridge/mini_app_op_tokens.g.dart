// GENERATED FILE — do not edit by hand.
// Source: tool/mini_app_op_index.txt
// Regenerate: dart run tool/generate_op_tokens.dart

/// Stable 16-hex tokens for every mini-app native-capability
/// op. The Dart-side family executor passes only these tokens
/// through the method channel; the Kotlin dispatcher resolves
/// token -> OpRoute via the encrypted table.
///
/// Replaces plaintext op names like "pkg.launch_on_display" so
/// the Dart AOT snapshot does not reveal the family namespace.
class MiniAppOpToken {
  const MiniAppOpToken._();

  /// display.amap_slot_marker
  static const String displayAmapSlotMarker = 'e6e68695d687ac7a';

  /// display.cluster_name_marker
  static const String displayClusterNameMarker = '0398326b04a090ce';

  /// gesture.input_swipe
  static const String gestureInputSwipe = 'b425c9821693e0e7';

  /// gesture.input_tap
  static const String gestureInputTap = '050883fd55a266ac';

  /// pkg.cluster_placeholder_component
  static const String pkgClusterPlaceholderComponent = 'ababd346995ec412';

  /// pkg.launch_on_display
  static const String pkgLaunchOnDisplay = 'dea75bdb7740be54';

  /// pkg.stack_list
  static const String pkgStackList = '32d1fb949b60ac5c';

  /// pkg.stack_move_task
  static const String pkgStackMoveTask = '9f1caa65a5487473';

  /// surface.am_start_cluster
  static const String surfaceAmStartCluster = '8019535f3c5a486f';

  /// surface.amap_force_stop
  static const String surfaceAmapForceStop = '1774bb3e78e104a4';

  /// All known tokens. Kept in sync with the index file.
  static const List<String> all = <String>[
    displayAmapSlotMarker,
    displayClusterNameMarker,
    gestureInputSwipe,
    gestureInputTap,
    pkgClusterPlaceholderComponent,
    pkgLaunchOnDisplay,
    pkgStackList,
    pkgStackMoveTask,
    surfaceAmStartCluster,
    surfaceAmapForceStop,
  ];
}
