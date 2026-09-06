/// Cold-start replay for `boot.write` declarations.
///
/// Mini-apps ★-pin packages via `boot.set({packageName, displayId})`.
/// Those rows persist in [BootStore] across reboots. [BootLauncher]
/// reads them after a fresh boot and replays each as a `pkg.launch`
/// against the same display the row recorded.
///
/// Detection of "fresh boot" uses the OS's boot epoch via
/// [BootNativeBridge] — `nowMs - elapsedRealtimeMs`. Comparing it
/// to a stored `lastReplayedBootEpochMs` in shared_preferences tells
/// us whether we've already replayed for this boot. Tolerates
/// device clock skew via a one-second equality window.
///
/// The [BootCompletedReceiver]-staged flag is a secondary signal:
/// non-zero `pendingAtMs` means a replay was definitely staged
/// recently. Either signal triggers a replay; both being negative
/// means we no-op silently.
///
/// Per-mini-app isolation is preserved by [BootStore.listAllFor]
/// returning every row under the active (user, deviceId); the launcher
/// dedupes by `(packageName, displayId)` so two mini-apps both
/// pinning Music to id=5 only fires one launch. Dedupe order
/// favours the earliest-set row (stable sort).
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import '../packaging/pkg_native_bridge.dart';
import 'boot_native_bridge.dart';
import 'boot_store.dart';

void _log(String msg) => developer.log(msg, name: 'BootLauncher');

/// Per-mini-app launch outcome — useful for the audit chain to
/// record what fired on each cold-start.
class BootReplayResult {
  const BootReplayResult({
    required this.entry,
    required this.ok,
    this.path,
    this.error,
  });

  final BootEntry entry;
  final bool ok;

  /// Mirrors `LaunchResult.path` from the pkg family — `intent-launch`
  /// for default-display rows, `am-start` for non-default, `denied`
  /// when the host couldn't launch.
  final String? path;
  final String? error;
}

class BootLauncher {
  BootLauncher({
    required BootStore store,
    required PkgNativeBridge pkgBridge,
    required BootNativeBridge bootBridge,
  }) : _store = store,
       _pkg = pkgBridge,
       _boot = bootBridge;

  final BootStore _store;
  final PkgNativeBridge _pkg;
  final BootNativeBridge _boot;

  /// SharedPreferences key for the last boot epoch we ran a replay
  /// for. Stored on the Flutter side (separate file from the
  /// receiver's flag) so the Dart code owns the "have we run yet"
  /// state cleanly without a cross-process write race.
  static const String _kLastReplayedBootEpochKey =
      'ilink.boot.last_replayed_boot_epoch_ms';

  /// Equality window for boot-epoch comparison. Wall clock can drift
  /// a few hundred ms across a reboot; treat anything within 1 s as
  /// "same boot".
  static const int _bootEpochSlackMs = 1000;

  /// Run the replay if this is a fresh boot for the active session.
  /// No-op when:
  ///   * Active session is null (caller is responsible — usually
  ///     called after auth resolves).
  ///   * Boot epoch matches the last replayed value within
  ///     [_bootEpochSlackMs] AND no receiver flag is pending.
  ///   * BootStore returns no rows for this (user, deviceId).
  ///
  /// Returns the per-row replay outcomes, empty if we no-op'd.
  Future<List<BootReplayResult>> runIfFreshBoot({
    required String userId,
    required String deviceId,
  }) async {
    final state = await _boot.bootState();
    final lastReplayed = await _readLastReplayedEpoch();
    final freshByEpoch =
        (state.bootEpochMs - lastReplayed).abs() > _bootEpochSlackMs;
    final freshByReceiver = state.pendingAtMs > 0;
    if (!freshByEpoch && !freshByReceiver) {
      _log(
        'no replay needed — bootEpoch=${state.bootEpochMs}'
        ' lastReplayed=$lastReplayed pending=${state.pendingAtMs}',
      );
      return const [];
    }

    final rows = await _store.listAllFor(userId: userId, deviceId: deviceId);
    if (rows.isEmpty) {
      _log(
        'fresh boot — no boot.write rows for ($userId, $deviceId); marking clean',
      );
      await _writeLastReplayedEpoch(state.bootEpochMs);
      await _boot.clearPending();
      return const [];
    }

    final deduped = _dedupe(rows);
    _log(
      'fresh boot — replaying ${deduped.length} row(s) '
      '(${rows.length - deduped.length} duped) for ($userId, $deviceId)',
    );

    final results = <BootReplayResult>[];
    for (final entry in deduped) {
      results.add(await _replayOne(entry));
    }

    await _writeLastReplayedEpoch(state.bootEpochMs);
    await _boot.clearPending();
    return results;
  }

  /// Backoff between the first try and the wms-transient retry.
  /// Long enough that the ROM's WMS state usually settles, short
  /// enough that it doesn't noticeably extend cold-start. Capped at
  /// one retry total — replays must not block boot indefinitely.
  static const Duration _wmsRetryBackoff = Duration(milliseconds: 500);

  Future<BootReplayResult> _replayOne(BootEntry entry) async {
    try {
      // BootEntry.displayId == -1 means "default" (IVI) — pkg.launch
      // accepts null for that. Map to null at this boundary so the
      // launch path picks Context.startActivity over am-start.
      final mappedDisplayId = entry.displayId < 0 ? null : entry.displayId;
      var result = await _pkg.launch(
        packageName: entry.packageName,
        displayId: mappedDisplayId,
      );
      // One retry, only on a wms-transient outcome. The host's
      // AmShellRunner already retried 250 ms after the first attempt;
      // 500 ms here gives the ROM another full settle window before
      // we give up. Not a loop — capped at exactly one retry so a
      // permanently-stuck ROM can't block cold-start.
      if (result.wmsTransient) {
        _log(
          'wms_transient replaying ${entry.packageName} '
          '(displayId=${entry.displayId}) — one retry after '
          '${_wmsRetryBackoff.inMilliseconds}ms',
        );
        await Future<void>.delayed(_wmsRetryBackoff);
        result = await _pkg.launch(
          packageName: entry.packageName,
          displayId: mappedDisplayId,
        );
      }
      _log(
        'replayed ${entry.packageName} '
        '(displayId=${entry.displayId}) ok=${result.ok} path=${result.path}',
      );
      return BootReplayResult(
        entry: entry,
        ok: result.ok,
        path: result.path,
        error: result.error,
      );
    } catch (e) {
      _log('replay ${entry.packageName} failed: $e');
      return BootReplayResult(entry: entry, ok: false, error: e.toString());
    }
  }

  /// Stable dedupe by `(packageName, displayId)`. First row wins —
  /// callers can rely on `BootStore.listAllFor` ordering by `app_id,
  /// package_name`, so the earliest registered mini-app gets the
  /// effective declaration. Two mini-apps both pinning Music to the
  /// same display = one launch.
  List<BootEntry> _dedupe(List<BootEntry> rows) {
    final seen = <String>{};
    final out = <BootEntry>[];
    for (final r in rows) {
      final key = '${r.packageName}@${r.displayId}';
      if (seen.add(key)) out.add(r);
    }
    return out;
  }

  Future<int> _readLastReplayedEpoch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLastReplayedBootEpochKey) ?? 0;
  }

  Future<void> _writeLastReplayedEpoch(int epochMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastReplayedBootEpochKey, epochMs);
  }
}
