/// Centralised registry of the Mini Apps surface tabs.
///
/// Why a registry: the prior implementation hard-coded `tabs` and
/// `views` arrays in `MiniAppsScreen.build`, plus a custom
/// `_tabCount = enabled ? 3 : 2` branch and a hand-rolled
/// `_rebuildController` clamp that worked only for the specific
/// 2 ↔ 3 transition. Adding a "Developer" or "Beta" section meant
/// editing the screen file, growing a boolean field, branching
/// `_rebuildController`, and threading a new listener. Each future
/// section grew the screen linearly.
///
/// The registry collapses that to one entry per section. Adding a
/// new tab is a one-liner — declare a [MiniAppSection], drop it in
/// the [miniAppSectionsProvider] list, done. The screen iterates
/// the *visible subset* and rebuilds the [TabController] only when
/// the visible count actually changes.
///
/// Visibility predicates take a [Ref] so a section can gate on any
/// reactive source — settings, capabilities, role, feature flag —
/// without leaking that source into the screen widget. Predicates
/// run inside [visibleMiniAppSectionsProvider]; the screen just
/// renders whatever falls out.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/settings/app_settings.dart';
import '../../native_apps/presentation/native_apps_tab.dart';
import '../../native_apps/state/native_app_store_controller.dart';
import '../presentation/widgets/flight_test_tab.dart';
import '../presentation/widgets/my_apps_tab.dart';
import '../presentation/widgets/store_tab.dart';

/// One tab in the Mini Apps surface. Stable [id] + [labelOf] +
/// [build] + a visibility predicate.
class MiniAppSection {
  const MiniAppSection({
    required this.id,
    required this.labelOf,
    required this.build,
    this.isVisible = _alwaysVisible,
  });

  /// Stable identifier — diagnostics + future selection persistence.
  /// Never localised.
  final String id;

  /// Tab title. Called per build with the active [S] localisation,
  /// so the registry stays locale-agnostic.
  final String Function(S t) labelOf;

  /// Builds the tab body. Const-friendly factories preferred.
  final Widget Function() build;

  /// Visibility predicate. Default: always visible. Override to gate
  /// on any reactive provider — settings, capabilities, role, etc.
  /// Runs inside [visibleMiniAppSectionsProvider]; MUST use
  /// `ref.watch` (not `ref.read`) to participate in re-renders.
  ///
  /// Convention: keep predicates pure projections of provider
  /// values; don't side-effect, don't await. Heavy gates live in
  /// their own providers that this predicate then watches.
  final bool Function(Ref ref) isVisible;

  static bool _alwaysVisible(Ref _) => true;
}

/// Single source of truth for the flight-test gate. Both the
/// FlightTest tab AND the developer-category filter in the Store
/// read this provider — flipping the setting propagates atomically.
///
/// Returns false until settings hydrate (first-launch race) — a
/// fail-closed default that hides developer surfaces until the user
/// has explicitly opted in.
final flightTestEnabledProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.flightTestModeEnabled ?? false,
    ),
  );
});

/// The canonical list of sections. Adding a new tab is one entry
/// here; everything downstream picks it up.
///
/// Order is the rendered order. Optional sections always go at the
/// end so flipping the flag doesn't shift indices of "always
/// visible" tabs the user is currently looking at.
final miniAppSectionsProvider = Provider<List<MiniAppSection>>((ref) {
  return [
    MiniAppSection(
      id: 'installed',
      labelOf: (t) => t.miniAppsTabInstalled,
      build: () => const MyAppsTab(),
    ),
    MiniAppSection(
      id: 'store',
      labelOf: (t) => t.miniAppsTabStore,
      build: () => const StoreTab(),
    ),
    // Native Apps — owner-facing storefront for third-party native
    // Android APKs. Gated by a build-time flag (default ON now the APK
    // Store has shipped fleet-wide); force off with
    // --dart-define=APP_NATIVE_STORE_ENABLED=false.
    MiniAppSection(
      id: 'native-apps',
      labelOf: (t) => t.miniAppsTabNativeApps,
      build: () => const NativeAppsTab(),
      isVisible: (ref) => ref.watch(nativeStoreEnabledProvider),
    ),
    // Flight Test — developer/beta-tester surface. Hidden until
    // Settings → Developer → "Flight test mode" is on.
    MiniAppSection(
      id: 'flight-test',
      labelOf: (t) => t.miniAppsTabFlightTest,
      build: () => const FlightTestTab(),
      isVisible: (ref) => ref.watch(flightTestEnabledProvider),
    ),
  ];
});

/// Visible subset — the only thing [MiniAppsScreen] needs.
/// Predicates run here; equality is structural by `id` order so
/// listeners only re-fire when the visible set actually changes.
final visibleMiniAppSectionsProvider = Provider<List<MiniAppSection>>((ref) {
  final all = ref.watch(miniAppSectionsProvider);
  return all.where((s) => s.isVisible(ref)).toList(growable: false);
});
