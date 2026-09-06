import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nav_hud_bridge.dart';

/// UI state for the Nav-HUD panel.
class NavHudState {
  const NavHudState({
    required this.probe,
    required this.armed,
    required this.pinned,
    required this.options,
    required this.busy,
    this.status = NavHudStatus.idle,
  });

  /// Live runtime status (polled while armed).
  final NavHudStatus status;

  /// Which cluster transports this car offers (M0 probe).
  final HudTransportProbe probe;

  /// Is the HUD currently driving the cluster?
  final bool armed;

  /// Pinned nav app, or null for auto-arbitrate.
  final NavApp? pinned;

  final NavHudOptions options;

  /// A native call is in flight.
  final bool busy;

  NavHudState copyWith({
    HudTransportProbe? probe,
    bool? armed,
    NavApp? pinned,
    bool clearPinned = false,
    NavHudOptions? options,
    bool? busy,
    NavHudStatus? status,
  }) => NavHudState(
    probe: probe ?? this.probe,
    armed: armed ?? this.armed,
    pinned: clearPinned ? null : (pinned ?? this.pinned),
    options: options ?? this.options,
    busy: busy ?? this.busy,
    status: status ?? this.status,
  );

  static const NavHudState initial = NavHudState(
    probe: HudTransportProbe.none,
    armed: false,
    pinned: null,
    options: NavHudOptions.defaults,
    busy: true,
  );
}

class NavHudController extends Notifier<NavHudState> {
  NavHudBridge get _bridge => ref.read(navHudBridgeProvider);
  Timer? _poll;
  bool _loaded = false;

  @override
  NavHudState build() {
    ref.onDispose(() => _poll?.cancel());
    return NavHudState.initial;
  }

  /// Run the native transport probe LAZILY — only when the Nav-HUD sheet is opened
  /// (its initState calls this), NOT when the Tools-strip ring merely reads `armed`.
  /// Eager-loading in build() leaked the probe's `.timeout` Timer into widget trees
  /// (home / onboarding / shell) that never open the sheet → test `!timersPending`.
  /// Idempotent.
  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  void _startPolling() {
    _poll?.cancel();
    _refreshStatus();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
    state = state.copyWith(status: NavHudStatus.idle);
  }

  Future<void> _refreshStatus() async {
    try {
      final s = await _bridge.status();
      state = state.copyWith(status: s);
      // Diagnostics: surface what the source actually read so the maneuver
      // (arrow) can be debugged on-car (logcat: `flutter`/`navhud`).
      if (s.armed && (s.drivingApp != null || s.maneuver != null)) {
        developer.log(
          'maneuver=${s.maneuver} raw="${s.rawManeuver}" '
          'road="${s.road}" dist=${s.distanceMeters} app=${s.drivingApp}',
          name: 'navhud',
        );
      }
    } catch (_) {
      // transient (e.g. channel busy) — keep the last status.
    }
  }

  Future<void> _load() async {
    // Always clear busy; degrade to no-transport on error instead of a frozen
    // spinner.
    try {
      final probe = await _bridge.probe().timeout(const Duration(seconds: 5));
      final options = await _bridge.options().timeout(
        const Duration(seconds: 5),
      );
      state = state.copyWith(probe: probe, options: options);
      // Sync with native: the HUD persists its on/off and auto-arms on app start,
      // so if it's already armed natively, reflect it here (toggle shows ON, status
      // polls) instead of making the user re-activate it every launch.
      final s = await _bridge.status().timeout(const Duration(seconds: 5));
      if (s.armed && !state.armed) {
        state = state.copyWith(armed: true, status: s);
        _startPolling();
      }
    } catch (_) {
      // keep last probe/options; the UI shows the "no transport" note.
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Re-run the transport probe (e.g. after the user grants access).
  Future<void> refresh() async {
    state = state.copyWith(busy: true);
    await _load();
  }

  /// Turn the HUD on/off (arm/disarm the native pipeline). Only flips `armed`
  /// after the native call succeeds; always clears `busy`.
  Future<void> setEnabled(bool on) async {
    if (state.busy) return; // ignore re-taps while a transition is in flight
    // Optimistic flip: the toggle moves IMMEDIATELY and polling starts so the
    // status card shows "Connecting…" → "Live". We do NOT wait for the native
    // arm() to return before flipping (it can take a few seconds to bind the
    // BYD service); waiting made the toggle look stuck ("can't flip"). Revert
    // only if the native call actually fails.
    state = state.copyWith(armed: on, busy: true);
    if (on) _startPolling();
    try {
      if (on) {
        await _bridge.arm().timeout(const Duration(seconds: 8));
      } else {
        await _bridge.disarm().timeout(const Duration(seconds: 8));
        _stopPolling();
      }
    } catch (_) {
      // Native arm/disarm failed — revert the optimistic flip.
      state = state.copyWith(armed: !on);
      if (on) _stopPolling();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Pin a nav app, or null to auto-arbitrate. Reverts the optimistic update if
  /// the native call fails.
  Future<void> pin(NavApp? app) async {
    final prev = state.pinned;
    state = state.copyWith(pinned: app, clearPinned: app == null);
    try {
      await _bridge.pin(app);
    } catch (_) {
      state = state.copyWith(pinned: prev, clearPinned: prev == null);
    }
  }

  Future<void> setOption(String key, bool value) async {
    try {
      final opts = await _bridge.setOption(key, value);
      state = state.copyWith(options: opts);
    } catch (_) {
      // keep the old option; the switch springs back.
    }
  }

  /// Set the cluster-protocol override (`auto`/`someip`/`canfid`). Takes effect on
  /// the next arm, so re-arm if currently armed.
  Future<void> setClusterProtocol(String value) async {
    try {
      final opts = await _bridge.setClusterProtocol(value);
      state = state.copyWith(options: opts);
      if (state.armed) {
        await _bridge.disarm();
        await _bridge.arm();
      }
    } catch (_) {
      // keep the old value.
    }
  }

  /// Set the SOME/IP wire variant (`auto`/`ui7`).
  ///
  /// Re-arms exactly like [setClusterProtocol] does — the variant decides which
  /// service ids `start()`/`stop()` use, so a flip while armed must be paired
  /// with a fresh arm rather than left half-applied.
  ///
  /// This is the revert path: picking `ui7` on the car pins the cluster wire to
  /// the bytes we ship and have proven today, with no rebuild.
  Future<void> setSomeIpVariant(String value) async {
    try {
      final opts = await _bridge.setSomeIpVariant(value);
      state = state.copyWith(options: opts);
      if (state.armed) {
        await _bridge.disarm();
        await _bridge.arm();
      }
    } catch (_) {
      // keep the old value.
    }
  }

  /// Push a synthetic maneuver to the cluster (transport smoke test).
  Future<void> sendTest() async {
    try {
      await _bridge.emitTest();
    } catch (_) {
      // channel error — ignore; status poll reflects reality.
    }
    await _refreshStatus();
  }
}

final navHudControllerProvider =
    NotifierProvider<NavHudController, NavHudState>(NavHudController.new);
