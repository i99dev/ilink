import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared lifecycle state and streams for local services and opted-in updates.
/// Streams dispatch asynchronously; subscribers read current state when an
/// asynchronous operation finishes instead of assuming the app is foreground.
class AppLifecycleBus extends WidgetsBindingObserver {
  AppLifecycleBus() {
    WidgetsBinding.instance.addObserver(this);
    _state =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  }

  final StreamController<AppLifecycleState> _all =
      StreamController<AppLifecycleState>.broadcast();
  final StreamController<void> _resumed = StreamController<void>.broadcast();
  final StreamController<void> _paused = StreamController<void>.broadcast();

  late AppLifecycleState _state;

  /// Most recent observed lifecycle state. Defaults to `resumed` until
  /// the engine reports otherwise — matches the implicit assumption in
  /// the old subsystems that didn't track state until the first
  /// callback fired.
  AppLifecycleState get state => _state;

  bool get isResumed => _state == AppLifecycleState.resumed;

  /// Every transition. Subscribers needing to handle paused/inactive/
  /// hidden separately use this directly instead of [onResumed]/[onPaused].
  Stream<AppLifecycleState> get onChange => _all.stream;

  /// Fires when the app foregrounds (state == resumed).
  Stream<void> get onResumed => _resumed.stream;

  /// Fires when the app becomes paused or hidden.
  Stream<void> get onPaused => _paused.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _state = state;
    _all.add(state);
    if (state == AppLifecycleState.resumed) {
      _resumed.add(null);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _paused.add(null);
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _all.close();
    _resumed.close();
    _paused.close();
  }
}

/// Single app-lifetime bus. Read-as-registration: nothing else needs
/// to construct this — every former observer subscribes to a stream
/// or reads `state` directly.
final appLifecycleBusProvider = Provider<AppLifecycleBus>((ref) {
  final bus = AppLifecycleBus();
  ref.onDispose(bus.dispose);
  return bus;
});
