import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/shell/shell_command.dart';
import '../../../kernel/shell/shell_ops_coordinator.dart';
import '../../../kernel/shell/shell_tool_bridge_provider.dart';
import '../data/connectivity_reader.dart';
import '../domain/connectivity_state.dart';

/// Polls the device for the union of all 5 connectivity values, batched
/// into ONE traversal of the shell bridge. Each individual circle on
/// the strip and each row in the Network mode sheet `select()`s into
/// the field it cares about, so a flap in only-cellular doesn't cause
/// a wifi rebuild.
///
/// Cadence:
///   * Foreground (sheet open OR strip visible) → 5s
///   * App background → suspended (Riverpod's autoDispose handles this)
///
/// Coordination: every read goes through [ShellOpsCoordinator], so
/// concurrent listeners share one in-flight Future per command.
class ConnectivityStateController extends AsyncNotifier<ConnectivityState> {
  Timer? _pollTimer;
  CancelToken? _activeCancel;
  static const _pollInterval = Duration(seconds: 5);

  @override
  Future<ConnectivityState> build() async {
    ref.onDispose(() {
      _pollTimer?.cancel();
      _activeCancel?.cancel(reason: 'provider disposed');
    });
    _schedulePoll();
    return _readOnce(seed: const ConnectivityState.unknown());
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) async {
      // Don't double-fire if a previous poll is still in flight; the
      // coordinator dedups but we save the wakeup if we're not sure
      // the previous Future settled.
      if (state.isLoading) return;
      try {
        final next = await _readOnce(
          seed: state.value ?? const ConnectivityState.unknown(),
        );
        if (state.value != next) {
          state = AsyncData(next);
        }
      } catch (e, st) {
        // Don't blow up the AsyncValue — keep last-known and surface
        // the error via debug logs only. The Network sheet has its
        // own REFRESH affordance for users to retry on demand.
        if (kDebugMode) {
          debugPrint('connectivity poll failed: $e\n$st');
        }
      }
    });
  }

  /// Manual refresh — REFRESH button in the Network mode sheet.
  Future<void> refresh() async {
    final coord = ref.read(shellOpsCoordinatorProvider);
    coord.invalidateAll();
    state = AsyncData(
      await _readOnce(seed: state.value ?? const ConnectivityState.unknown()),
    );
  }

  /// Single point through which the controller patches state during
  /// optimistic toggles — keeps `.state` writes encapsulated in the
  /// notifier (Riverpod's lint flags external `.state =`).
  void patch(ConnectivityState next) {
    state = AsyncData(next);
  }

  Future<ConnectivityState> _readOnce({required ConnectivityState seed}) async {
    final coord = ref.read(shellOpsCoordinatorProvider);
    final cancel = CancelToken(reason: 'replaced by next poll');
    _activeCancel?.cancel(reason: 'replaced by next poll');
    _activeCancel = cancel;

    // Fire all 6 reads concurrently. The coordinator dedups — if the
    // sheet opens during a poll, both callers share the same future.
    Future<String?> safeRead(String cacheKey, List<String> argv) async {
      try {
        return await coord.read(
          ShellCommand(argv, cacheKey: cacheKey),
          cancel: cancel,
        );
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      safeRead('dumpsys wifi', const ['dumpsys', 'wifi']),
      safeRead('dumpsys bluetooth_manager', const [
        'dumpsys',
        'bluetooth_manager',
      ]),
      // Cellular state read switched from `svc data` → settings.global
      // (see ConnectivityReader.parseCellular for the rationale). The
      // cacheKey is also the writer's _kCellKey so a successful
      // setCellular() invalidates exactly this entry.
      safeRead('settings get global mobile_data', const [
        'settings',
        'get',
        'global',
        'mobile_data',
      ]),
      safeRead('dumpsys telephony.registry', const [
        'dumpsys',
        'telephony.registry',
      ]),
      safeRead('settings get global data_roaming', const [
        'settings',
        'get',
        'global',
        'data_roaming',
      ]),
      safeRead('dumpsys wifi softap', const [
        'sh',
        '-c',
        'dumpsys wifi | grep -iE "softap|tethering" | head -5 || true',
      ]),
    ]);

    return ConnectivityReader.compose(
      previous: seed,
      wifiDump: results[0],
      btDump: results[1],
      mobileDataSetting: results[2],
      telephonyDump: results[3],
      roamingSetting: results[4],
      hotspotDump: results[5],
    );
  }
}

/// Use `select()` on this provider in widgets to scope rebuilds to a
/// single field — see [tools_panel.dart] and the network mode sheet.
final connectivityStateProvider =
    AsyncNotifierProvider<ConnectivityStateController, ConnectivityState>(
      ConnectivityStateController.new,
    );
