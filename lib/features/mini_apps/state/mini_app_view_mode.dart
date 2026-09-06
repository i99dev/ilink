import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// View mode for the mini-apps screen. Cards are the default for visual
/// browsing; list is denser and better for scanning many apps quickly.
enum MiniAppViewMode { grid, list }

/// Persists the user's preferred view mode across app launches.
class MiniAppViewModeController extends Notifier<MiniAppViewMode> {
  static const _key = 'miniapps.view_mode';

  @override
  MiniAppViewMode build() {
    // Hydrate asynchronously; the initial state is `grid` until the
    // first read completes — that's the desktop-default for a brand
    // new install too, so no jank from the late hydration.
    Future.microtask(_hydrate);
    return MiniAppViewMode.grid;
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == 'list') {
      state = MiniAppViewMode.list;
    }
  }

  Future<void> set(MiniAppViewMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  Future<void> toggle() => set(
    state == MiniAppViewMode.grid ? MiniAppViewMode.list : MiniAppViewMode.grid,
  );
}

final miniAppViewModeProvider =
    NotifierProvider<MiniAppViewModeController, MiniAppViewMode>(
      MiniAppViewModeController.new,
    );
