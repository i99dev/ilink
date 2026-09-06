import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_command.dart';
import '../shell/shell_tool_bridge_provider.dart';
import 'sim_identity_override.dart';

/// Resolved SIM identity for the rest of the app.
///
/// Two layers stacked, override wins:
///   1. Real prop — `persist.radio.iccid` (and the volatile mirror
///      `ril.csim.iccid` as a fallback) read via the existing shell
///      bridge. Empty string when the SIM isn't present or the prop
///      hasn't been populated yet.
///   2. Override — when [SimIdentityOverride.active], the user-picked
///      ICCID+IMSI replaces whatever layer 1 returned.
///
/// Consumers should treat this as the authoritative app view of "what
/// SIM are we on" — the real prop is intentionally hidden behind the
/// override so a single read site stays consistent across UI surfaces.
@immutable
class ResolvedSimIdentity {
  const ResolvedSimIdentity({
    required this.iccid,
    required this.imsi,
    required this.overrideActive,
    required this.realIccid,
  });

  /// Visible ICCID — override when [overrideActive], else the prop
  /// readback. Empty string when neither is available (no SIM, no
  /// override, shell unreachable).
  final String iccid;

  /// Visible IMSI. Only populated when [overrideActive]; for the
  /// real path we don't have a reliable read without
  /// READ_PHONE_STATE, so this stays empty in pass-through mode.
  final String imsi;

  /// True when the user's spoof override is the source of [iccid]
  /// and [imsi]. UI surfaces a "Overridden" badge in that case.
  final bool overrideActive;

  /// The real prop value, regardless of override. Surfaced
  /// separately so the UI can show "real: X / shown: Y" side by
  /// side when the user toggles between modes.
  final String realIccid;

  static const empty = ResolvedSimIdentity(
    iccid: '',
    imsi: '',
    overrideActive: false,
    realIccid: '',
  );
}

/// Polls the real `persist.radio.iccid` via the shell bridge. Kept
/// internal because consumers should depend on the override-aware
/// [resolvedSimIdentityProvider] below.
///
/// We try `persist.radio.iccid` first (persistent across reboots);
/// fall back to `ril.csim.iccid` (volatile mirror the modem
/// refreshes on SIM state change). Reading both costs nothing
/// observable — each `getprop` is a sub-100ms shell exec.
final _realIccidProvider = FutureProvider<String>((ref) async {
  final bridge = ref.watch(shellToolBridgeProvider);
  Future<String> read(String key) async {
    try {
      final out = await bridge.exec(
        ShellCommand(['getprop', key], timeoutMs: 2000),
      );
      return out.trim();
    } catch (_) {
      return '';
    }
  }

  final persistVal = await read('persist.radio.iccid');
  if (persistVal.isNotEmpty) return persistVal;
  return read('ril.csim.iccid');
});

/// Override-aware resolved identity. UI surfaces watch this; the
/// override controller can be mutated independently and the value
/// here recomputes via Riverpod's dependency tracking.
final resolvedSimIdentityProvider = Provider<ResolvedSimIdentity>((ref) {
  final overrideAsync = ref.watch(simIdentityOverrideProvider);
  final realAsync = ref.watch(_realIccidProvider);
  final real = realAsync.value ?? '';
  final override = overrideAsync.value ?? SimIdentityOverride.empty;
  if (override.active && override.current != null) {
    return ResolvedSimIdentity(
      iccid: override.current!.iccid,
      imsi: override.current!.imsi,
      overrideActive: true,
      realIccid: real,
    );
  }
  return ResolvedSimIdentity(
    iccid: real,
    imsi: '',
    overrideActive: false,
    realIccid: real,
  );
});
