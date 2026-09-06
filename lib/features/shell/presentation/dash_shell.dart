import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/access/feature_gate.dart';
import '../../../kernel/ui/responsive/breakpoints.dart';
import '../../../kernel/access/cockpit_direction.dart';
import '../../../kernel/access/feature_policy.dart';
import '../../../features/_car_domain/command/action_ids.dart';
import '../../../features/_car_domain/_car_domain.dart';
import '../../../sdk/car/client.dart';
import '../../../sdk/car/providers.dart';
import '../../../platform/location/location_service.dart';
import '../../assistant/presentation/widgets/assistant_content_panel.dart';
import '../../assistant/presentation/widgets/assistant_stop_on_tap.dart';
import '../../assistant/presentation/widgets/voice_hud.dart';
import '../../assistant/state/voice_background_feedback.dart';
import '../../assistant/state/voice_playback_coordinator.dart';
import '../../home/presentation/widgets/bubble_toggle_button.dart';
import '../../home/presentation/widgets/top_status_bar.dart';
import '../../themes/presentation/widgets/theme_wallpaper_layer.dart';
import '../../mini_apps/presentation/mini_apps_screen.dart';
import '../../settings/presentation/pages/settings_page.dart';
import '../state/active_screen_controller.dart';
import 'screens/home_screen.dart';
import 'screens/radio_screen.dart';
import 'screens/tv_screen.dart';
import 'widgets/dash_pill_dock.dart';
import 'widgets/floating_mic.dart';
import 'widgets/integrity_banner.dart';

// Root of the app post-redesign. Persistent TopStatusBar at the top,
// PageView body, floating pill dock at the bottom.
//
// The set of visible screens is the same in dev + production today —
// dev-only controls live under the diagnostics page (gate-probe section).
// that stacks every actuator control (climate, windows, quick-actions,
// comfort rail) plus the compat scanner. See [visibleScreensProvider]
// below for the source of truth.
class DashShell extends ConsumerStatefulWidget {
  const DashShell({super.key});

  @override
  ConsumerState<DashShell> createState() => _DashShellState();
}

class _DashShellState extends ConsumerState<DashShell> {
  late final PageController _pager = PageController();

  @override
  void initState() {
    super.initState();
    // Debug-only: diff Dart ActionIds.all against Kotlin knownActions().
    // No-op in release and under mock mode.
    Future.microtask(
      () => ref
          .read(carClientProvider)
          .verifyActionContract(expected: ActionIds.all),
    );
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BreakpointProvider(
      child: Scaffold(
        body: SafeArea(child: _ShellBody(pager: _pager)),
      ),
    );
  }
}

// Split from DashShell so its context is _below_ BreakpointProvider —
// otherwise `context.bp` can't resolve.
class _ShellBody extends ConsumerWidget {
  const _ShellBody({required this.pager});
  final PageController pager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    void snack(String msg) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: cs.surfaceContainerHigh,
        ),
      );
    }

    void openSettings() => Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));

    final visible = ref.watch(visibleScreensProvider);
    // Hold a reference so its `ref.listen` stays alive for the lifetime
    // of the shell — auto-stops the mic when an audio tool starts
    // playback (radio etc.) so the assistant's reply doesn't fight the
    // speaker. Silent tools (weather query, open window) don't trigger
    // the listener and the mic stays open for chained commands.
    ref.watch(voicePlaybackCoordinatorProvider);
    // Pushes the live voice phase to the native bubble so a backgrounded
    // wheel-button user sees listening/thinking/speaking/command feedback.
    ref.watch(voiceBackgroundFeedbackProvider);

    // If the active screen just got hidden (dev mode flipped off while
    // on Climate), snap back to Home.
    ref.listen<List<DashScreen>>(visibleScreensProvider, (_, next) {
      final active = ref.read(activeScreenProvider);
      if (!next.contains(active)) {
        ref.read(activeScreenProvider.notifier).go(DashScreen.home);
      }
    });

    // Keep the PageController aligned with the active screen — whether it
    // changed via tap, external push, or a visible-list reshuffle.
    ref.listen<DashScreen>(activeScreenProvider, (_, next) {
      if (!pager.hasClients) return;
      final targetIndex = visible.indexOf(next);
      if (targetIndex < 0) return;
      if (pager.page?.round() == targetIndex) return;
      pager.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });

    // Driver-side anchoring (mic, bubble button, and every cockpit
    // subtree) is now centralised in [CockpitDirectionality] +
    // [PositionedDirectional] / `start`/`end` insets — no widget on
    // this screen reads `driverSide` directly any more. A flip in
    // Settings → Display → Driver side rebuilds the cockpit provider,
    // and every directional placement underneath repaints with the
    // new edge.
    return CockpitDirectionality(
      child: Stack(
        children: [
          // Active-theme wallpaper, painted behind the whole shell. A
          // no-op when no theme is active or it ships no wallpaper —
          // the default look is unchanged (THEMES_CONTRACT.md §6/§7).
          const ThemeWallpaperLayer(),
          Column(
            children: [
              TopStatusBar(onSettings: openSettings),
              const IntegrityBanner(),
              Expanded(
                child: PageView(
                  key: ValueKey(
                    visible.length,
                  ), // rebuild on visible-set change
                  controller: pager,
                  // Horizontal swipe between screens, snapping to pages.
                  // Tapping the pill dock still drives the same pager via
                  // the activeScreenProvider listener above, so swipe and
                  // tap stay in lockstep.
                  physics: const PageScrollPhysics(),
                  onPageChanged: (i) {
                    if (i < 0 || i >= visible.length) return;
                    final screen = visible[i];
                    if (ref.read(activeScreenProvider) != screen) {
                      ref.read(activeScreenProvider.notifier).go(screen);
                    }
                  },
                  children: [
                    for (final screen in visible) _screenFor(screen, snack),
                  ],
                ),
              ),
              // Reserve the space the floating dock consumes so PageView
              // content doesn't draw under it.
              const SizedBox(height: _dockReservedBottom),
            ],
          ),
          // Tap-to-cancel: when the assistant is running, any tap on the
          // page area below stops the session. Sits BELOW the dock and
          // the assistant cards in the Stack so those remain interactive
          // (otherwise the user couldn't tap a quick-action card the AI
          // surfaced, or use the dock to switch screens). Renders nothing
          // — and adds zero hit-test surface — when the assistant is
          // idle, so it has no perf cost in the common case.
          const AssistantStopOnTap(),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: DashPillDock()),
          ),
          // Floating mic + bubble-minimize button — pinned to the
          // driver-side bottom corner so they stick across every screen
          // (home, mini-apps, radio, dev). Live in the shell's Stack
          // rather than each screen so a screen transition can't leave
          // the user without their primary controls.
          //
          // Bottom-left action row: bubble (minimize-to-bubble overlay)
          // → FloatingMic. PositionedDirectional pins to the driver-side
          // edge.
          const PositionedDirectional(
            bottom: 22,
            start: 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                BubbleToggleButton(),
                SizedBox(width: 12),
                FloatingMic(),
              ],
            ),
          ),
          // Assistant visual cards sit just above the floating dock.
          // Sibling to VoiceHud so they share the overlay z-layer but
          // don't nest — keeping them peers means the HUD's tap-to-
          // interrupt surface and the cards' tap targets stay independent.
          const Positioned(
            left: 24,
            right: 24,
            bottom: 108,
            child: AssistantContentPanel(),
          ),
          const VoiceHud(),
          const _KeepAlive(),
        ],
      ),
    );
  }

  Widget _screenFor(DashScreen screen, void Function(String) onResult) {
    switch (screen) {
      case DashScreen.home:
        return const HomeScreen();
      case DashScreen.radio:
        // Tiering — radio is bundle-gated; show the screen dimmed with an
        // upgrade overlay when the car lacks `content.radio`.
        return const FeatureGate(
          feature: Feature.radio,
          lockedMode: LockedRenderMode.disable,
          child: RadioScreen(),
        );
      case DashScreen.miniApps:
        return const MiniAppsScreen();
      case DashScreen.tv:
        return const FeatureGate(
          feature: Feature.tv,
          lockedMode: LockedRenderMode.disable,
          child: TvScreen(),
        );
    }
  }

  // Height of the dock + breathing room. Tweak if DashPillDock sizes change
  // so PageView content doesn't flow under the floating dock.
  static const double _dockReservedBottom = 96;
}

class _KeepAlive extends ConsumerWidget {
  const _KeepAlive();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Cheap watch keeps the SDK's daemon-liveness poll mounted across
    // screen switches so the 2 s probe doesn't tear down/up. Mirrors
    // the long-lived registry subscription that powers every tile.
    ref.watch(daemonReadyProvider);
    // Always-on GPS subscription. The original ``LocationBridge.kt``
    // (removed Apr 20 2026 with the map screen) ran the LocationManager
    // request continuously while the map widget was mounted, which kept
    // the GNSS chip warm 24/7. Without that subscription, Geolocator's
    // stream sleeps when no widget watches it — and ``LocationService.
    // freshFix`` then has to cold-start the chip on every voice session
    // (5 s+ on a parked car, often returning the OS's stale cached
    // fix). Keeping a cheap watch here matches what Google Maps / Waze
    // do: a process-wide subscription that nudges the OS to keep
    // streaming positions, populating ``_lastStreamFix`` so callers
    // always have a recent value to read.
    ref.watch(currentLocationProvider);
    return const SizedBox.shrink();
  }
}

/// Ordered list of screens visible in the dock. Same set in dev and
/// production — pre-May 2026 dev mode inserted a `dev` page here that
/// stacked the climate / windows / quick-action panels. That page moved
/// into the diagnostics page (under the gate-probe section) so the
/// dock stays production-shaped. Ordering is load-bearing — it's the
/// source of truth for PageView children, pill-dock items, and the
/// pager index math.
final visibleScreensProvider = Provider<List<DashScreen>>((ref) {
  return const [
    DashScreen.home,
    DashScreen.miniApps,
    DashScreen.radio,
    DashScreen.tv,
  ];
});
