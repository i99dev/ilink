import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lifecycle phases of the loopback-ADB + DashDaemon bring-up.
/// Mirrors `AdbSetupPhase` in
/// `android/app/src/main/kotlin/com/i99dev/ilink/adb/AdbSetupState.kt`.
enum AdbSetupPhase {
  /// Daemon up + connected, or no run in flight. Overlay hidden.
  idle,

  /// Loopback ADB connection is being opened. The system "Allow USB
  /// debugging?" prompt is either visible or imminent — the overlay
  /// renders the contextual explainer card behind it.
  authorizing,

  /// ADB authorised; spawning DashDaemon over the shell. Overlay
  /// shows a "Setting up background services" message.
  spawning,

  /// Daemon is up and pinging. Overlay auto-dismisses.
  ready,

  /// Bring-up failed. Overlay shows the error + Try again button.
  failed,
}

class AdbSetupSnapshot {
  const AdbSetupSnapshot({required this.phase, this.error});

  const AdbSetupSnapshot.idle() : phase = AdbSetupPhase.idle, error = null;

  factory AdbSetupSnapshot.fromMap(Map<Object?, Object?> map) {
    return AdbSetupSnapshot(
      phase: _phaseFromString(map['phase'] as String?),
      error: map['error'] as String?,
    );
  }

  final AdbSetupPhase phase;
  final String? error;

  bool get isOverlayVisible =>
      phase == AdbSetupPhase.authorizing ||
      phase == AdbSetupPhase.spawning ||
      phase == AdbSetupPhase.failed;

  static AdbSetupPhase _phaseFromString(String? s) => switch (s) {
    'Authorizing' => AdbSetupPhase.authorizing,
    'Spawning' => AdbSetupPhase.spawning,
    'Ready' => AdbSetupPhase.ready,
    'Failed' => AdbSetupPhase.failed,
    _ => AdbSetupPhase.idle,
  };
}

/// Thin wrapper around the `ilink/adb_setup` method + event
/// channels. iOS / web / test builds don't register the platform
/// side; the wrapper degrades to a static idle snapshot in that case.
class AdbSetupChannel {
  AdbSetupChannel({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel(_kMethodChannel),
      _events = events ?? const EventChannel(_kEventChannel);

  static const _kMethodChannel = 'ilink/adb_setup';
  static const _kEventChannel = 'ilink/adb_setup/events';

  final MethodChannel _method;
  final EventChannel _events;

  Future<AdbSetupSnapshot> getCurrent() async {
    try {
      final raw = await _method.invokeMapMethod<Object?, Object?>('getCurrent');
      if (raw == null) return const AdbSetupSnapshot.idle();
      return AdbSetupSnapshot.fromMap(raw);
    } on MissingPluginException {
      return const AdbSetupSnapshot.idle();
    } on PlatformException {
      return const AdbSetupSnapshot.idle();
    }
  }

  /// Forces a fresh daemon spawn. Phase transitions stream back via
  /// the event channel; the returned snapshot is the post-retry
  /// state (typically [AdbSetupPhase.ready] on success or
  /// [AdbSetupPhase.failed] otherwise).
  Future<AdbSetupSnapshot> retry() async {
    try {
      final raw = await _method.invokeMapMethod<Object?, Object?>('retry');
      if (raw == null) return const AdbSetupSnapshot.idle();
      return AdbSetupSnapshot.fromMap(raw);
    } on MissingPluginException {
      return const AdbSetupSnapshot.idle();
    } on PlatformException catch (e) {
      return AdbSetupSnapshot(
        phase: AdbSetupPhase.failed,
        error: e.message ?? e.code,
      );
    }
  }

  Stream<AdbSetupSnapshot> events() {
    return _events
        .receiveBroadcastStream()
        .map((event) {
          if (event is Map) {
            return AdbSetupSnapshot.fromMap(event.cast<Object?, Object?>());
          }
          return const AdbSetupSnapshot.idle();
        })
        .handleError((Object _) => const AdbSetupSnapshot.idle());
  }
}

final adbSetupChannelProvider = Provider<AdbSetupChannel>((_) {
  return AdbSetupChannel();
});

/// Session-scoped flag: set when the user dismisses a daemon setup-FAILURE
/// dialog. While set, [DaemonSetupOverlay] stays hidden so the forever-retrying
/// bring-up doesn't re-pop the dialog every cycle on ROMs where the daemon
/// can't spawn (e.g. the UI7 ROM, where adbd isn't on the legacy loopback
/// port). The core Nav-HUD runs fine without the daemon (SOME/IP needs no
/// shell). Cleared on a successful `ready` phase and on app restart.
class DaemonSetupFailedDismissed extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state != value) state = value;
  }
}

final daemonSetupFailedDismissedProvider =
    NotifierProvider<DaemonSetupFailedDismissed, bool>(
      DaemonSetupFailedDismissed.new,
    );

/// Live phase stream. Seeds with `getCurrent()` so the first frame
/// after subscription has a real snapshot, then folds in event-channel
/// updates. Closes the subscription on dispose so a route teardown
/// doesn't leak a native stream.
final adbSetupStateProvider = StreamProvider<AdbSetupSnapshot>((ref) async* {
  final channel = ref.read(adbSetupChannelProvider);
  yield await channel.getCurrent();
  final controller = StreamController<AdbSetupSnapshot>();
  final sub = channel.events().listen(
    controller.add,
    onError: (Object _) {
      // Swallow — channel errors degrade to "no overlay".
    },
  );
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  yield* controller.stream;
});
