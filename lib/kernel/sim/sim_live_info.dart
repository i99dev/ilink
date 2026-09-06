import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_command.dart';
import '../shell/shell_tool_bridge.dart';
import '../shell/shell_tool_bridge_provider.dart';

/// Live, modem-side network info read from `getprop` and exposed to
/// the USIM sheet so the user doesn't have to leave iLINK to inspect
/// what the BYD system "Network Information" dialog would show.
///
/// All fields are best-effort strings (the prop or `''` when missing /
/// unread). Consumers render a placeholder for empty fields rather
/// than dropping the row, so a missing IMSI is visible as "—" instead
/// of confusingly absent.
@immutable
class SimLiveInfo {
  const SimLiveInfo({
    required this.imsi,
    required this.imei,
    required this.simState,
    required this.operatorName,
    required this.operatorNumeric,
  });

  /// `ril.imsi`. Empty when no SIM is registered with the modem.
  final String imsi;

  /// `ril.imei`. Stable per slot; never empty on a real head unit
  /// (the IMEI is baked into the modem hardware, not the SIM).
  final String imei;

  /// `gsm.sim.state` raw value. One of:
  ///   * `UNKNOWN` — modem hasn't reported yet
  ///   * `ABSENT` — no SIM in slot
  ///   * `PIN_REQUIRED` / `PUK_REQUIRED` / `NETWORK_LOCKED` — locked
  ///   * `READY` / `LOADED` — usable
  ///   * `NOT_READY` — slot inserted but still initialising
  final String simState;

  /// `gsm.operator.alpha` — display name (e.g. "etisalat", "China Mobile").
  /// Empty when no SIM or when the carrier doesn't broadcast a name.
  final String operatorName;

  /// `gsm.operator.numeric` — 5-or-6 digit MCC+MNC (e.g. "42402", "46000").
  /// Empty when no SIM. Pair with [operatorName] in the UI.
  final String operatorNumeric;

  static const empty = SimLiveInfo(
    imsi: '',
    imei: '',
    simState: 'UNKNOWN',
    operatorName: '',
    operatorNumeric: '',
  );

  /// Convenience: is there a usable SIM-shaped thing in the slot?
  /// True only when the modem reports a non-empty state that isn't
  /// `ABSENT` / `UNKNOWN`. Empty IMSI alone isn't enough — some BYD
  /// ROMs leave `ril.imsi` blank for a PIN-locked SIM that's still
  /// present.
  bool get simPresent {
    final s = simState.toUpperCase();
    return s.isNotEmpty && s != 'ABSENT' && s != 'UNKNOWN';
  }
}

/// 10-second poll cadence. Each tick is 5 `getprop` invocations
/// batched into a single shell call (joined with `;`) so the device
/// pays one MethodChannel hop per refresh, not five.
///
/// Why 10s: matches the dashboard's other "live but not real-time"
/// surfaces (presence cache, status freshness). Tighter polling would
/// burn shell-bridge cycles for values that change at SIM-state
/// granularity (insert / remove / register), not sub-second.
const _kPollInterval = Duration(seconds: 10);

const _kBatchedProps = <String>[
  'ril.imsi',
  'ril.imei',
  'gsm.sim.state',
  'gsm.operator.alpha',
  'gsm.operator.numeric',
];

/// One-shot read of the batched props. Public so tests can exercise
/// the parser without setting up a StreamProvider lifecycle.
Future<SimLiveInfo> readSimLiveInfo(ShellToolBridge bridge) async {
  try {
    // Single shell call with `getprop key1; getprop key2; …` so we
    // pay one round-trip. Each line of output corresponds to one
    // prop in [_kBatchedProps] order; empty props become empty lines.
    final argv = <String>['sh', '-c'];
    final cmd = _kBatchedProps.map((k) => 'getprop $k').join('; ');
    argv.add(cmd);
    final out = await bridge.exec(ShellCommand(argv, timeoutMs: 3000));
    final lines = out.split('\n').map((l) => l.trim()).toList();
    // Pad / truncate to exactly the expected length so an
    // unexpected extra newline can't shift the field assignments.
    while (lines.length < _kBatchedProps.length) {
      lines.add('');
    }
    return SimLiveInfo(
      imsi: lines[0],
      imei: lines[1],
      simState: lines[2].isEmpty ? 'UNKNOWN' : lines[2],
      operatorName: lines[3],
      operatorNumeric: lines[4],
    );
  } catch (_) {
    return SimLiveInfo.empty;
  }
}

/// Polls modem state and exposes it as a stream. Re-yields on each
/// poll tick so consumers using `ref.watch(simLiveInfoProvider)`
/// re-render even when only one field changed.
///
/// Cancellation: a completer wired to `ref.onDispose` lets the
/// poll loop bail out within milliseconds of the consumer going
/// away — otherwise the test container's `dispose()` would race
/// the 10-second `Future.delayed` and leak the subscription.
///
/// Failure mode: a shell exception (daemon down, timeout) emits
/// [SimLiveInfo.empty] and the next tick retries. We deliberately
/// don't surface the error to the UI — a temporary daemon hiccup
/// shouldn't blank the panel with a red banner.
final simLiveInfoProvider = StreamProvider<SimLiveInfo>((ref) async* {
  final bridge = ref.watch(shellToolBridgeProvider);
  final cancel = Completer<void>();
  ref.onDispose(() {
    if (!cancel.isCompleted) cancel.complete();
  });

  yield await readSimLiveInfo(bridge);
  while (!cancel.isCompleted) {
    await Future.any([Future<void>.delayed(_kPollInterval), cancel.future]);
    if (cancel.isCompleted) return;
    yield await readSimLiveInfo(bridge);
  }
});
