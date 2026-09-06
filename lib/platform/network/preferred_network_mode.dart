import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subset of the Android `TelephonyManager.NETWORK_MODE_*` constants
/// we expose as a user-facing picker. The full set has 30+ values
/// covering every CDMA / TD-SCDMA / NR-SA combination — most of which
/// are irrelevant on the GSM-family radio in the Leopard 8. We
/// surface the four "generations" plus "Auto" because that's what a
/// non-engineer driver actually wants to switch between.
// Android `TelephonyManager.NETWORK_TYPE_BITMASK_*` values, which are
// `1 << (NETWORK_TYPE - 1)`. These feed the privileged headless force
// path `cmd phone set-allowed-network-types-for-users <BITMASK>` —
// confirmed present on the DiLink5.0 L5 (127.0.0.1:5999, 2026-05-16:
// `get-allowed-network-types-for-users` → `GPRS|EDGE|GSM|NR`). Kept
// here (not Kotlin) so the mapping is `flutter test`-covered; Kotlin
// only executes the resolved integer. Any edit here is a wire change
// to the modem — `preferred_network_mode_test.dart` pins every value.
const int _bmGsm = 1 << 15; // GSM(16)    32768
const int _bmGprs = 1 << 0; // GPRS(1)    1
const int _bmEdge = 1 << 1; // EDGE(2)    2
const int _bmUmts = 1 << 2; // UMTS(3)    4
const int _bmHsdpa = 1 << 7; // HSDPA(8)  128
const int _bmHsupa = 1 << 8; // HSUPA(9)  256
const int _bmHspa = 1 << 9; // HSPA(10)   512
const int _bmHspap = 1 << 14; // HSPAP(15) 16384
const int _bmLte = 1 << 12; // LTE(13)    4096
const int _bmNr = 1 << 19; // NR(20)      524288

const int _bm2g = _bmGsm | _bmGprs | _bmEdge; // 32771
const int _bm3g = _bmUmts | _bmHsdpa | _bmHsupa | _bmHspa | _bmHspap; // 17284
// "4G" stays LTE-only to match the existing `fourG` semantics +
// `preferred_network_mode=11` (drops to no-data if LTE is absent —
// documented tradeoff, unchanged by the force path).
const int _bm4g = _bmLte; // 4096
const int _bmAuto = _bmLte | _bm3g | _bm2g; // 54151 (no NR — picker
// hides 5G; no BYD trim we ship has NR head-unit hardware)
const int _bm5g = _bmAuto | _bmNr; // 578439

@immutable
class PreferredNetworkMode {
  const PreferredNetworkMode({
    required this.id,
    required this.label,
    required this.allowedTypesBitmask,
  });

  /// Raw `preferred_network_mode` integer the radio reads from
  /// [Settings.Global]. See `NetworkInfoChannel.kt` for the full
  /// mapping table.
  final int id;

  /// Short human label (`"AUTO"`, `"5G"`, etc). The full localised
  /// title + help live in the UI section's l10n keys; this is just
  /// the inline pill label.
  final String label;

  /// `TelephonyManager.NETWORK_TYPE_BITMASK_*` OR-set for the
  /// privileged force path (`cmd phone
  /// set-allowed-network-types-for-users`). Distinct namespace from
  /// [id] (which is the `Settings.Global.preferred_network_mode`
  /// int): `id` is the *stored preference*, this is what the modem
  /// is *forced* to allow so the change actually takes effect
  /// without an airplane-mode reload.
  final int allowedTypesBitmask;

  /// Auto — LTE + WCDMA + GSM with auto-fallback. Default on the
  /// Leopard 8 (`preferred_network_mode=9` in the captured settings).
  static const auto = PreferredNetworkMode(
    id: 9,
    label: 'AUTO',
    allowedTypesBitmask: _bmAuto,
  );

  /// 5G + LTE + WCDMA + GSM. Picks 5G when available, otherwise
  /// falls back through 4G → 3G → 2G.
  static const fiveG = PreferredNetworkMode(
    id: 36,
    label: '5G',
    allowedTypesBitmask: _bm5g,
  );

  /// LTE-only. Drops calls if the network needs to fall back to 3G
  /// (rare in 4G+ markets, common in older areas).
  static const fourG = PreferredNetworkMode(
    id: 11,
    label: '4G',
    allowedTypesBitmask: _bm4g,
  );

  /// WCDMA-only (3G).
  static const threeG = PreferredNetworkMode(
    id: 2,
    label: '3G',
    allowedTypesBitmask: _bm3g,
  );

  /// GSM-only (2G). Edge / GPRS — usable for SMS + voice but not
  /// modern data. Drains less battery; useful for parked
  /// long-running diagnostics.
  static const twoG = PreferredNetworkMode(
    id: 1,
    label: '2G',
    allowedTypesBitmask: _bm2g,
  );

  /// Mode chips rendered on the picker.
  ///
  /// Trimmed to **Auto / 4G / 2G** because:
  ///   * **5G** — no BYD trim we ship to has 5G hardware in the head
  ///     unit's radio. Listing it leads users to "select 5G" → the
  ///     ROM either rejects or silently downshifts, and we'd surface
  ///     a "ROM reverted" warning every time.
  ///   * **3G** — Etisalat (and most carriers we care about) have
  ///     decommissioned 3G; the option is dead weight, and on a
  ///     2G/4G-only car the chip never gets picked.
  ///
  /// The [fiveG] and [threeG] **constants stay defined** so
  /// [fromId] can still resolve a stored `preferred_network_mode=36`
  /// or `=2` to a labelled instance (e.g. after a profile migration
  /// or a value the user set via system settings). They just don't
  /// render as chips. Restore them here when a trim ships with the
  /// hardware to back them.
  static const all = <PreferredNetworkMode>[auto, fourG, twoG];

  /// Resolve a stored integer back to one of [all], or null if the ROM
  /// reports a value we don't surface (e.g. CDMA-only modes). Caller
  /// renders that case as "Custom: $id" so the user sees something
  /// rather than a confusing default.
  static PreferredNetworkMode? fromId(int? id) {
    if (id == null) return null;
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is PreferredNetworkMode && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// How a [PreferredNetworkModeController.forceApply] actually landed.
///   * [modem]        — the privileged headless path
///     (`cmd phone set-allowed-network-types-for-users`) applied it
///     to the radio for real. The change is live now.
///   * [radioInfo]    — headless path was refused by the ROM; the
///     host opened the `com.android.phone` RadioInfo Activity so the
///     user can apply it there. Action still required from the user.
///   * [reverted]     — wrote the preference but the radio read back
///     a different value and no force path took (BYD-known quirk).
///   * [channelMissing] — the native channel isn't wired (web/iOS).
enum NetworkModeApplied { modem, radioInfo, reverted, channelMissing }

/// Outcome of [PreferredNetworkModeController.set] / [forceApply].
/// Surfaced to the UI so the user sees "forced" / "open Phone Info"
/// / "didn't take" / "channel missing".
@immutable
class NetworkModeWriteOutcome {
  const NetworkModeWriteOutcome({
    required this.ok,
    required this.value,
    this.error,
    this.via = NetworkModeApplied.reverted,
  });
  final bool ok;
  final int? value;
  final String? error;

  /// Which path took. `set()` only ever produces [reverted]-style
  /// outcomes shaped as before (back-compat); `forceApply()` sets
  /// this meaningfully so the UI can distinguish "forced on the
  /// modem" from "go finish it in Phone Info".
  final NetworkModeApplied via;
}

/// MethodChannel handle. Held as a top-level constant so the
/// provider + controller — and `connectivity_provider.dart`'s
/// `cellularGenerationProvider` — share one identity. Flutter
/// requires every MethodChannel call to use the same channel name
/// string; a single const ensures we can't drift the name on one
/// side. Public so sibling files in `lib/platform/network/` can reuse
/// the same handle without re-declaring the wire name.
const networkInfoMethodChannel = MethodChannel('ilink/network_info');

/// Async snapshot of the current preferred-network-mode integer the
/// ROM reports. Polls once on first watch + on explicit
/// [PreferredNetworkModeController.refresh]. Doesn't auto-poll
/// because the value is stable for minutes-to-hours at a time and
/// every read is a shell exec.
class PreferredNetworkModeController extends AsyncNotifier<int?> {
  /// SharedPreferences key that persists the user's last picked
  /// mode across app launches. Survives reinstalls too (the file
  /// lives in the app sandbox, not in flash that's wiped per build).
  static const _kPrefsKey = 'preferred_network_mode.user_selection.v1';

  @override
  Future<int?> build() async {
    final saved = await _readSavedPref();
    final current = await _read();
    // Re-arm the saved selection on every app launch.
    //
    // Why this is needed: BYD ROMs (and some carrier interactions)
    // occasionally reset `Settings.Global.preferred_network_mode`
    // back to Auto (9) after a reboot or radio reload, even though
    // the user previously picked e.g. 2G or 4G-only. Without this,
    // the user has to re-pick their mode every cold start. Re-
    // applying turns the picker into a "remembered choice" with the
    // same UX you'd expect from a phone's network-mode setting.
    //
    // Only re-applies when (a) there IS a saved choice and (b) it
    // diverges from what the radio currently reports. On Auto carry-
    // over the no-op fast-path saves a daemon round-trip per launch.
    if (saved != null && saved != current) {
      // Optimistic: emit saved immediately so the chip reflects the
      // user's pick from frame 1, even before the re-arm completes.
      // The set() below will overwrite state.value with the
      // post-readback value (usually saved, occasionally the ROM-
      // reverted fallback).
      final mode = PreferredNetworkMode.fromId(saved);
      if (mode != null) {
        // Fire-and-forget — the re-arm runs in the background; UI
        // already has the optimistic value via the return below.
        unawaited(_silentReapply(mode));
      }
      return saved;
    }
    return current;
  }

  Future<int?> _read() async {
    try {
      return await networkInfoMethodChannel.invokeMethod<int>(
        'getPreferredNetworkMode',
      );
    } on MissingPluginException {
      return null; // web / iOS / desktop
    } on PlatformException {
      return null; // shell unreachable, key unset, etc.
    }
  }

  Future<int?> _readSavedPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_kPrefsKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _savePref(int mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefsKey, mode);
    } catch (_) {
      // Best-effort: failure to persist doesn't fail the set() call.
      // Next app launch will fall back to whatever the ROM reports.
    }
  }

  /// Re-apply on app start without surfacing UI feedback. Errors
  /// are swallowed — if the daemon is unreachable at boot, the next
  /// poll or user tap will retry. The state notifier still gets the
  /// post-write readback so the chip highlight matches reality.
  Future<void> _silentReapply(PreferredNetworkMode mode) async {
    try {
      final raw = await networkInfoMethodChannel
          .invokeMapMethod<String, Object?>('setPreferredNetworkMode', {
            'mode': mode.id,
          });
      final value = raw?['value'] as int?;
      if (value != null) state = AsyncValue.data(value);
    } catch (_) {
      // Silent on boot — user can retry from the picker.
    }
  }

  /// Re-poll the daemon for the current mode. Use after [set] to
  /// reflect what the ROM actually applied (which may differ from
  /// what we wrote — see [NetworkModeWriteOutcome.ok]).
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = AsyncValue.data(await _read());
  }

  /// Apply [mode] via the shell-UID daemon. Returns a structured
  /// outcome so the UI can render "didn't take" warnings.
  ///
  /// Persists [mode] to SharedPreferences before invoking the
  /// daemon, so even when the bridge is transiently down the user's
  /// choice survives — `build()` will re-arm it on the next launch.
  Future<NetworkModeWriteOutcome> set(PreferredNetworkMode mode) async {
    // Persist FIRST so a daemon-side failure doesn't lose the user's
    // intent. The re-arm path will retry on next launch.
    await _savePref(mode.id);
    try {
      final raw = await networkInfoMethodChannel
          .invokeMapMethod<String, Object?>('setPreferredNetworkMode', {
            'mode': mode.id,
          });
      final ok = raw?['ok'] as bool? ?? false;
      final value = raw?['value'] as int?;
      final error = raw?['error'] as String?;
      // Optimistic state update — the UI flips immediately even before
      // the explicit refresh below. If `ok` is false, this still
      // reflects what the ROM read back, which is what the picker
      // should highlight.
      state = AsyncValue.data(value);
      return NetworkModeWriteOutcome(ok: ok, value: value, error: error);
    } on MissingPluginException {
      return const NetworkModeWriteOutcome(
        ok: false,
        value: null,
        error: 'channel-not-available',
      );
    } on PlatformException catch (e) {
      return NetworkModeWriteOutcome(ok: false, value: null, error: e.message);
    }
  }

  /// Force [mode] onto the radio for real.
  ///
  /// Unlike [set] (which only writes the stored
  /// `Settings.Global.preferred_network_mode` preference and waits
  /// for the ROM to maybe pick it up), this routes through the
  /// privileged headless path
  /// `cmd phone set-allowed-network-types-for-users
  /// <[PreferredNetworkMode.allowedTypesBitmask]>` on the shell-UID
  /// bridge — confirmed present on the DiLink5.0 L5. That hits the
  /// modem immediately, no airplane-mode reload (so the loopback ADB
  /// bridge never drops) and no on-screen Activity. If the ROM
  /// refuses the headless call the host falls back to opening the
  /// `com.android.phone` RadioInfo Activity ([NetworkModeApplied.
  /// radioInfo]) so the user can apply it there.
  ///
  /// Persists the choice first (same as [set]) so a transient bridge
  /// failure doesn't lose intent; `build()` re-arms on next launch.
  Future<NetworkModeWriteOutcome> forceApply(PreferredNetworkMode mode) async {
    await _savePref(mode.id);
    try {
      final raw = await networkInfoMethodChannel
          .invokeMapMethod<String, Object?>('forceApplyNetworkMode', {
            'mode': mode.id,
            'bitmask': mode.allowedTypesBitmask,
          });
      final ok = raw?['ok'] as bool? ?? false;
      final value = raw?['value'] as int?;
      final error = raw?['error'] as String?;
      final path = raw?['path'] as String?;
      state = AsyncValue.data(value);
      return NetworkModeWriteOutcome(
        ok: ok,
        value: value,
        error: error,
        via: switch (path) {
          'modem' => NetworkModeApplied.modem,
          'radioinfo-activity' => NetworkModeApplied.radioInfo,
          _ => NetworkModeApplied.reverted,
        },
      );
    } on MissingPluginException {
      return const NetworkModeWriteOutcome(
        ok: false,
        value: null,
        error: 'channel-not-available',
        via: NetworkModeApplied.channelMissing,
      );
    } on PlatformException catch (e) {
      return NetworkModeWriteOutcome(
        ok: false,
        value: null,
        error: e.message,
        via: NetworkModeApplied.reverted,
      );
    }
  }
}

final preferredNetworkModeProvider =
    AsyncNotifierProvider<PreferredNetworkModeController, int?>(
      PreferredNetworkModeController.new,
    );
