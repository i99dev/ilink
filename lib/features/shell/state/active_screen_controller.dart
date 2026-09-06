import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/observability/observability.dart';

/// All possible screens the DashShell may render. Which ones are actually
/// visible in a given run depends on `devCarControlsEnabled` (see
/// `visibleScreensProvider` in `dash_shell.dart`). The enum lists every
/// screen the app knows about regardless of mode — the visible-list
/// provider picks the subset.
///
/// `miniApps` hosts the Store + My Apps surface (see
/// `features/mini_apps/`). It's in the production nav because the
/// sandbox + install state are host-side concerns — the dock showing
/// it does not require the backend catalog to be live; the Store tab
/// degrades to its empty state until `MINIAPPS_BACKEND=api` is flipped.
///
/// History: pre-May 2026 a top-level `dev` screen lived here (a
/// dock-pinned page that stacked climate + windows + quick actions +
/// compat scanner). The page was demoted into the diagnostics page
/// (under the dev-mode-gated Gate Probe section) to keep the dock
/// production-shaped even when dev mode is on. `DevScreen` itself
/// is kept on disk dormant for restoration.
enum DashScreen { home, radio, miniApps, tv }

class ActiveScreenController extends Notifier<DashScreen> {
  @override
  DashScreen build() => DashScreen.home;

  void go(DashScreen s) {
    final from = state;
    state = s;
    // Breadcrumb every screen transition. The "driver screen changes
    // by itself" bug needs the chain of go() calls leading up to the
    // mystery jump — this gives us that chain in any captured event.
    Observability.breadcrumb(
      category: 'nav.active_screen',
      message: 'go',
      data: {'from': from.name, 'to': s.name},
    );
  }
}

final activeScreenProvider =
    NotifierProvider<ActiveScreenController, DashScreen>(
      ActiveScreenController.new,
    );
