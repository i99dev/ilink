import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/shell/shell_tool_bridge_provider.dart';
import '../data/connectivity_writer.dart';
import '../domain/connectivity_state.dart';
import 'connectivity_state_provider.dart';

/// Result of a toggle attempt. UI shows ok / err for ~700ms.
enum ToggleOutcome { ok, failed }

/// Public connectivity capability tag — call sites pass one of these
/// to [ConnectivityController.toggle].
enum ToolCapability { wifi, bluetooth, cellular, roaming, hotspot }

/// Performs connectivity toggles. Optimistic UI: the
/// [connectivityStateProvider] is patched to `transitioning` immediately,
/// the shell write fires, and the next poll round-trips the truth. On
/// shell failure we revert and surface the error.
class ConnectivityController extends Notifier<void> {
  late final ConnectivityWriter _writer;

  @override
  void build() {
    _writer = ConnectivityWriter(ref.read(shellOpsCoordinatorProvider));
  }

  /// Generic toggle — `cap` selects which capability changes, the
  /// rest is dispatched. Keeps the controller's surface tiny vs N
  /// methods per capability.
  Future<ToggleOutcome> toggle(ToolCapability cap, NetState desired) async {
    final pre = _patchOptimistic(cap, NetState.transitioning);
    try {
      switch (cap) {
        case ToolCapability.wifi:
          await _writer.setWifi(desired);
        case ToolCapability.bluetooth:
          await _writer.setBluetooth(desired);
        case ToolCapability.cellular:
          await _writer.setCellular(desired);
        case ToolCapability.roaming:
          await _writer.setRoaming(desired);
        case ToolCapability.hotspot:
          await _writer.setHotspot(desired);
      }
      // Trigger an immediate refresh so the strip reflects the change
      // before the 5s poll boundary.
      await ref.read(connectivityStateProvider.notifier).refresh();
      return ToggleOutcome.ok;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('toggle ${cap.name} → $desired failed: $e\n$st');
      }
      // Revert optimistic patch on failure — the user sees the toggle
      // snap back, the toast surfaces the error.
      ref.read(connectivityStateProvider.notifier).patch(pre);
      return ToggleOutcome.failed;
    }
  }

  // Convenience aliases for the most common call sites — keeps row
  // builders terse without exposing a generic `cap` arg in 5 places.
  Future<ToggleOutcome> toggleWifi(NetState desired) =>
      toggle(ToolCapability.wifi, desired);
  Future<ToggleOutcome> toggleBluetooth(NetState desired) =>
      toggle(ToolCapability.bluetooth, desired);
  Future<ToggleOutcome> toggleCellular(NetState desired) =>
      toggle(ToolCapability.cellular, desired);
  Future<ToggleOutcome> toggleRoaming(NetState desired) =>
      toggle(ToolCapability.roaming, desired);
  Future<ToggleOutcome> toggleHotspot(NetState desired) =>
      toggle(ToolCapability.hotspot, desired);

  ConnectivityState _patchOptimistic(ToolCapability cap, NetState s) {
    final asyncState = ref.read(connectivityStateProvider);
    final pre = asyncState.value ?? const ConnectivityState.unknown();
    final next = switch (cap) {
      ToolCapability.wifi => pre.copyWith(wifi: s),
      ToolCapability.bluetooth => pre.copyWith(bluetooth: s),
      ToolCapability.cellular => pre.copyWith(cellular: s),
      ToolCapability.roaming => pre.copyWith(roaming: s),
      ToolCapability.hotspot => pre.copyWith(hotspot: s),
    };
    ref.read(connectivityStateProvider.notifier).patch(next);
    return pre;
  }
}

final connectivityControllerProvider =
    NotifierProvider<ConnectivityController, void>(ConnectivityController.new);
