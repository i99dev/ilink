/// Owns the active page index for the dashboard's [PageView]. Single-
/// owner state: every read of "which page is showing" goes through
/// this provider, every write goes through `set(int)` from the
/// [DashboardScreen]'s onPageChanged callback.
///
/// Kept as a separate provider (instead of widget-local state) so
/// future surfaces — voice ("go to apps page"), deep-link routing,
/// telemetry — can drive the dashboard without reaching through the
/// widget tree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class DashboardPageController extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) {
    if (index < 0) return;
    if (state != index) state = index;
  }
}

final dashboardPageControllerProvider =
    NotifierProvider<DashboardPageController, int>(DashboardPageController.new);
