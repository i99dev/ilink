import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/lifecycle/app_lifecycle_bus.dart';
import '../../mini_apps/packaging/pkg_snapshot.dart';
import 'installed_apps_provider.dart';

/// Polling cadence for the running-apps view. The underlying
/// `pkg.running` op shells `am stack list` (~50–100 ms) plus a
/// microsecond-class regex parse, so 2 s is comfortably under any
/// load-bearing budget. Callers that need an instant refresh after a
/// launch / move should `ref.invalidate(runningAppsRefreshTickProvider)`
/// so the next read re-fetches without waiting for the next tick.
const _kPollPeriod = Duration(seconds: 2);

/// Refresh-tick provider — a monotonically-increasing int the
/// [runningAppsProvider] watches. When the home pane is mounted, a
/// timer drives it forward every [_kPollPeriod]. After a successful
/// launch / move the UI bumps it manually for sub-tick latency:
///
///     ref.read(runningAppsRefreshTickProvider.notifier).bump();
class RunningAppsRefreshTick extends Notifier<int> {
  Timer? _timer;
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

  @override
  int build() {
    final bus = ref.read(appLifecycleBusProvider);
    _retune(bus.isResumed);
    _lifecycleSub = bus.onChange.listen((state) {
      _retune(state == AppLifecycleState.resumed);
    });
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _lifecycleSub?.cancel();
    });
    return 0;
  }

  void _retune(bool foreground) {
    _timer?.cancel();
    _timer = null;
    // Background apps don't need a 2s `am stack list` shell-out — the
    // user can't see the chip strip, so the result would be invisible
    // until the next resume. Resume rearms via the bus listener.
    if (foreground) {
      _timer = Timer.periodic(_kPollPeriod, (_) => state = state + 1);
    }
  }

  /// Force the next read of [runningAppsProvider] to hit the bridge,
  /// bypassing the polling cadence. Cheap — same as letting the timer
  /// fire one period early.
  void bump() => state = state + 1;
}

final runningAppsRefreshTickProvider =
    NotifierProvider<RunningAppsRefreshTick, int>(RunningAppsRefreshTick.new);

/// Single source of truth for "what's running where." Watches the
/// refresh tick + the bridge; emits a `Map<displayId, List<RunningTask>>`
/// so the per-display chip strip can do `running[displayId]` in O(1).
///
/// `autoDispose` so the polling timer stops the moment the home pane
/// (the only listener) leaves the tree. Mini-app surfaces, viewer, etc.
/// don't subscribe — there's no battery cost when the user is in
/// another part of the app.
///
/// Failure mode: bridge throws → empty map (the home pane just shows
/// no chips). The next tick retries; transient `am stack list` flakes
/// don't permanently degrade the view.
final runningAppsProvider =
    FutureProvider.autoDispose<Map<int, List<RunningTask>>>((ref) async {
      ref.watch(runningAppsRefreshTickProvider);
      final bridge = ref.watch(pkgBridgeProvider);
      try {
        final rows = await bridge.running();
        final byDisplay = <int, List<RunningTask>>{};
        // Dedupe by PACKAGE NAME (not taskId): on Di5.1/L8 the
        // fresh-launch-only path for ReVanced + similar apps spawns a
        // SECOND task on the cluster via `am start --display N
        // --activity-multiple-task` and leaves the original IVI task
        // alive but visible=false. Both rows surface in `am stack list`
        // with DIFFERENT taskIds + the SAME packageName, so a taskId-
        // based dedupe lets the chip duplicate on both Head Unit and
        // Driver cards. Keying on packageName + a foreground-first
        // sort keeps the chip on the user-visible display (the cluster
        // for the fresh-launch case) and drops the invisible IVI
        // ghost — the operator interacts with the visible instance
        // anyway, and showing a chip for a backgrounded copy was the
        // duplicated-icon complaint behind 2026-05-20 P10.
        final seen = <String>{};
        for (final r
            in rows.where((r) => r.packageName != 'com.i99dev.ilink').toList()
              ..sort((a, b) {
                // Prefer SECONDARY display over the IVI default. The
                // observed live state for a cluster-moved fresh-launch-
                // only app (ReVanced + similar) is:
                //   taskId=N on displayId=0 visible=true  (the IVI ghost)
                //   taskId=M on displayId=5 visible=true  (the cluster
                //                                          instance the
                //                                          operator wants)
                // Foreground alone tie-breaks both → we need a stronger
                // signal. Operator-intent is "I dragged it to the
                // cluster," so the secondary-display row wins the dedup
                // and the chip ends up on the Driver card.
                final aSecondary = a.displayId != 0;
                final bSecondary = b.displayId != 0;
                if (aSecondary != bSecondary) return aSecondary ? -1 : 1;
                if (a.isForeground != b.isForeground) {
                  return a.isForeground ? -1 : 1;
                }
                return 0;
              })) {
          if (!seen.add(r.packageName)) continue;
          (byDisplay[r.displayId] ??= <RunningTask>[]).add(r);
        }
        // Stable ordering inside each display — foreground first, then
        // the rest by package name. Keeps the chip strip from jittering
        // between polls when ActivityManagerService re-orders tasks.
        for (final list in byDisplay.values) {
          list.sort((a, b) {
            if (a.isForeground != b.isForeground) {
              return a.isForeground ? -1 : 1;
            }
            return a.packageName.compareTo(b.packageName);
          });
        }
        return byDisplay;
      } catch (e, st) {
        debugPrint('runningAppsProvider failed: $e\n$st');
        return const <int, List<RunningTask>>{};
      }
    });
