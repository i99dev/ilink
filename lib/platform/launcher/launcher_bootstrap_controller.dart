import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/sdk/_internal/logger.dart';
import 'launcher_privilege_status.dart';

/// One result entry from the per-command grant pass. The Diagnostics UI
/// renders these inline next to each privilege row after a Grant-all
/// run so the user can see exactly which `pm grant` succeeded and
/// which the HU rejected.
class LauncherGrantResult {
  const LauncherGrantResult({
    required this.key,
    required this.ok,
    required this.output,
  });

  /// Stable key — matches the field name on [LauncherPrivilegeStatus]
  /// that this command targets (`readLogs`, `mediaContentControl`,
  /// `packageUsageStats`).
  final String key;

  /// Whether the command came back without an error string. False here
  /// means the HU rejected the grant — typical reasons: the perm is
  /// signature-only on the vendor build, the manifest doesn't declare
  /// it (post-install change without a rebuild), or `shell` doesn't
  /// have ADB-grant authority on this ROM. The raw [output] from the
  /// command is preserved for triage.
  final bool ok;

  /// Raw stdout/stderr from the shell call. Empty string on
  /// success — `pm grant` and `appops set` print nothing when they
  /// succeed.
  final String output;

  factory LauncherGrantResult.fromMap(Map<dynamic, dynamic> raw) {
    return LauncherGrantResult(
      key: (raw['key'] as String?) ?? '',
      ok: raw['ok'] == true,
      output: (raw['output'] as String?) ?? '',
    );
  }
}

/// Aggregate outcome of a [LauncherBootstrapChannel.grantAll] call.
class LauncherGrantOutcome {
  const LauncherGrantOutcome({
    required this.ok,
    required this.results,
    this.unreachableReason,
  });

  /// True iff every individual command succeeded AND the bridge was
  /// reachable.
  final bool ok;

  /// Per-command results. Empty when the bridge probe failed (no
  /// commands were attempted in that case).
  final List<LauncherGrantResult> results;

  /// Set when the bridge couldn't be reached at all (cold pair window,
  /// adbd not on, daemon not yet ready). Surfaced to the UI so the
  /// user sees "ADB not reachable" rather than "everything failed".
  final String? unreachableReason;

  factory LauncherGrantOutcome.fromMap(Map<dynamic, dynamic> raw) {
    final reason = raw['reason'] as String?;
    if (reason == 'adb_unreachable') {
      return LauncherGrantOutcome(
        ok: false,
        results: const [],
        unreachableReason: (raw['detail'] as String?) ?? 'adb_unreachable',
      );
    }
    final list = (raw['results'] as List?) ?? const [];
    return LauncherGrantOutcome(
      ok: raw['ok'] == true,
      results: [
        for (final r in list)
          if (r is Map) LauncherGrantResult.fromMap(r),
      ],
    );
  }
}

/// Outcome of [LauncherBootstrapChannel.requestDefaultHome] — opens a
/// system picker, so "ok" means "the picker was launched", not "we
/// became default home". The user's actual choice is observable via
/// [LauncherPrivilegeStatus.isDefaultHome] on the next probe; the
/// controller invalidates the status provider after this call so the
/// grid auto-refreshes when the user navigates back to Diagnostics.
class LauncherDefaultHomeOutcome {
  const LauncherDefaultHomeOutcome({
    required this.ok,
    this.method,
    this.unreachableReason,
    this.aliasEnableFailureDetail,
    this.noPickerActivityDetail,
  });

  final bool ok;

  /// Which strategy actually launched: `role_manager` (API 29+ clean
  /// path) or `home_settings` (legacy fallback). Surface so the
  /// support UI can hint "look for the home-app picker" vs "look for
  /// the role-grant dialog".
  final String? method;

  /// Set on the rare PackageManager error path (legacy v1 only —
  /// removed when the dispatcher stopped using ADB for set-home).
  /// Kept on the model so an older Kotlin shipping the v1 payload
  /// still parses cleanly.
  final String? unreachableReason;

  /// Set when the alias enable precondition failed (PackageManager
  /// rejected the toggle, e.g. component name typo after a refactor).
  final String? aliasEnableFailureDetail;

  /// Set when neither RoleManager nor Settings.ACTION_HOME_SETTINGS
  /// resolved on the HU — extremely rare, would mean the vendor build
  /// has stripped both the role API and the home-settings activity.
  final String? noPickerActivityDetail;

  factory LauncherDefaultHomeOutcome.fromMap(Map<dynamic, dynamic> raw) {
    final reason = raw['reason'] as String?;
    if (reason == 'adb_unreachable') {
      return LauncherDefaultHomeOutcome(
        ok: false,
        unreachableReason: (raw['detail'] as String?) ?? 'adb_unreachable',
      );
    }
    if (reason == 'alias_enable_failed') {
      return LauncherDefaultHomeOutcome(
        ok: false,
        aliasEnableFailureDetail: (raw['detail'] as String?) ?? 'unknown',
      );
    }
    if (reason == 'no_picker_activity') {
      return LauncherDefaultHomeOutcome(
        ok: false,
        noPickerActivityDetail: (raw['detail'] as String?) ?? 'unknown',
      );
    }
    return LauncherDefaultHomeOutcome(
      ok: raw['ok'] == true,
      method: raw['method'] as String?,
    );
  }
}

/// Outcome of [LauncherBootstrapChannel.enableAccessibilityServices].
/// Re-stamps the system's enabled-accessibility-services CSV via two
/// shell commands; ok iff both come back without an error string.
class LauncherA11yEnableOutcome {
  const LauncherA11yEnableOutcome({
    required this.ok,
    this.unreachableReason,
    this.results = const [],
  });

  final bool ok;
  final String? unreachableReason;
  final List<({String cmd, bool ok, String output})> results;

  factory LauncherA11yEnableOutcome.fromMap(Map<dynamic, dynamic> raw) {
    final reason = raw['reason'] as String?;
    if (reason == 'adb_unreachable') {
      return LauncherA11yEnableOutcome(
        ok: false,
        unreachableReason: (raw['detail'] as String?) ?? 'adb_unreachable',
      );
    }
    final list = (raw['results'] as List?) ?? const [];
    return LauncherA11yEnableOutcome(
      ok: raw['ok'] == true,
      results: [
        for (final r in list)
          if (r is Map)
            (
              cmd: (r['cmd'] as String?) ?? '',
              ok: r['ok'] == true,
              output: (r['output'] as String?) ?? '',
            ),
      ],
    );
  }
}

/// Thin wrapper around `ilink/launcher_bootstrap`. Stays
/// stateless — Riverpod owns the orchestration via
/// [launcherBootstrapControllerProvider] below.
class LauncherBootstrapChannel {
  const LauncherBootstrapChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_kChannel);

  static const _kChannel = 'ilink/launcher_bootstrap';
  static const _log = Logger('LauncherBootstrap');

  final MethodChannel _channel;

  /// Issue every launcher-tier `pm grant` / `appops set` command
  /// over loopback ADB. Idempotent. Safe to call when launcher mode
  /// is OFF — the grants land regardless; they only take effect
  /// when the alias is enabled.
  Future<LauncherGrantOutcome> grantAll() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'grantAll',
      );
      if (raw == null) {
        return const LauncherGrantOutcome(ok: false, results: []);
      }
      return LauncherGrantOutcome.fromMap(raw);
    } on PlatformException catch (e) {
      _log.e('grantAll failed: ${e.code} ${e.message}');
      return LauncherGrantOutcome(
        ok: false,
        results: const [],
        unreachableReason: 'channel_error: ${e.message ?? e.code}',
      );
    }
  }

  /// Flip the [HomeActivityAlias] component-enabled state. No ADB
  /// needed — we own the component. Throws on PackageManager error
  /// (rare; would mean the manifest declared a component name we
  /// don't actually have).
  Future<void> setLauncherModeEnabled(bool enabled) async {
    await _channel.invokeMethod<void>(
      'setLauncherModeEnabled',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// Open the system's default-home picker so the user can pick us.
  /// Auto-enables the alias as a precondition. The picker is a system
  /// UI — `ok` here means "the picker launched"; the user's actual
  /// pick lands in [LauncherPrivilegeStatus.isDefaultHome] which the
  /// controller refreshes when invalidating the status provider.
  Future<LauncherDefaultHomeOutcome> requestDefaultHome() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestDefaultHome',
      );
      if (raw == null) return const LauncherDefaultHomeOutcome(ok: false);
      return LauncherDefaultHomeOutcome.fromMap(raw);
    } on PlatformException catch (e) {
      _log.e('requestDefaultHome failed: ${e.code} ${e.message}');
      return LauncherDefaultHomeOutcome(
        ok: false,
        unreachableReason: 'channel_error: ${e.message ?? e.code}',
      );
    }
  }

  /// Re-stamp the system's enabled-accessibility-services CSV so our
  /// RemoteControl + Watchdog services bind. Idempotent (the awk
  /// de-dup keeps the CSV clean on repeat). Recovery path for the
  /// case where the OS panel has silently disabled our services after
  /// AdbBootstrap already ran — the watchdog detects this; this
  /// method lets the user fix it without rebooting.
  Future<LauncherA11yEnableOutcome> enableAccessibilityServices() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'enableAccessibilityServices',
      );
      if (raw == null) return const LauncherA11yEnableOutcome(ok: false);
      return LauncherA11yEnableOutcome.fromMap(raw);
    } on PlatformException catch (e) {
      _log.e('enableAccessibilityServices failed: ${e.code} ${e.message}');
      return LauncherA11yEnableOutcome(
        ok: false,
        unreachableReason: 'channel_error: ${e.message ?? e.code}',
      );
    }
  }
}

final launcherBootstrapChannelProvider = Provider<LauncherBootstrapChannel>(
  (ref) => const LauncherBootstrapChannel(),
);

/// Reactive state surfaced by the bootstrap UI. Distinct from the
/// privilege snapshot — this captures the in-flight / last-completed
/// state of the user-initiated actions (Grant all, Make home), so the
/// UI can show progress + per-row outcomes inline.
class LauncherBootstrapState {
  const LauncherBootstrapState({
    this.busy = false,
    this.lastGrant,
    this.lastDefaultHome,
    this.lastA11y,
  });

  /// True while any bootstrap call is in flight. The buttons disable
  /// themselves on this so a user can't fire two overlapping shell
  /// sessions.
  final bool busy;

  final LauncherGrantOutcome? lastGrant;
  final LauncherDefaultHomeOutcome? lastDefaultHome;
  final LauncherA11yEnableOutcome? lastA11y;

  LauncherBootstrapState copyWith({
    bool? busy,
    LauncherGrantOutcome? lastGrant,
    LauncherDefaultHomeOutcome? lastDefaultHome,
    LauncherA11yEnableOutcome? lastA11y,
  }) {
    return LauncherBootstrapState(
      busy: busy ?? this.busy,
      lastGrant: lastGrant ?? this.lastGrant,
      lastDefaultHome: lastDefaultHome ?? this.lastDefaultHome,
      lastA11y: lastA11y ?? this.lastA11y,
    );
  }
}

class LauncherBootstrapController extends Notifier<LauncherBootstrapState> {
  @override
  LauncherBootstrapState build() => const LauncherBootstrapState();

  /// Run the launcher-tier grant set, then invalidate the privilege
  /// status provider so the grid refreshes with the new state.
  Future<LauncherGrantOutcome> grantAll() async {
    if (state.busy) return state.lastGrant ?? _emptyGrant;
    state = state.copyWith(busy: true);
    try {
      final outcome = await ref
          .read(launcherBootstrapChannelProvider)
          .grantAll();
      state = state.copyWith(busy: false, lastGrant: outcome);
      ref.invalidate(launcherPrivilegeStatusProvider);
      return outcome;
    } catch (_) {
      state = state.copyWith(busy: false);
      rethrow;
    }
  }

  /// Toggle the home alias on/off. Doesn't itself make us default
  /// home — that needs [setAsDefaultHome] (or a manual user pick).
  Future<void> setLauncherModeEnabled(bool enabled) async {
    if (state.busy) return;
    state = state.copyWith(busy: true);
    try {
      await ref
          .read(launcherBootstrapChannelProvider)
          .setLauncherModeEnabled(enabled);
      ref.invalidate(launcherPrivilegeStatusProvider);
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Open the system home-picker. Auto-enables the alias.
  Future<LauncherDefaultHomeOutcome> requestDefaultHome() async {
    if (state.busy) return state.lastDefaultHome ?? _emptyDefault;
    state = state.copyWith(busy: true);
    try {
      final outcome = await ref
          .read(launcherBootstrapChannelProvider)
          .requestDefaultHome();
      state = state.copyWith(busy: false, lastDefaultHome: outcome);
      ref.invalidate(launcherPrivilegeStatusProvider);
      return outcome;
    } catch (_) {
      state = state.copyWith(busy: false);
      rethrow;
    }
  }

  /// Recovery action for the a11y services. Re-stamps the
  /// enabled-services CSV without re-running the full AdbBootstrap.
  Future<LauncherA11yEnableOutcome> enableAccessibilityServices() async {
    if (state.busy) return state.lastA11y ?? _emptyA11y;
    state = state.copyWith(busy: true);
    try {
      final outcome = await ref
          .read(launcherBootstrapChannelProvider)
          .enableAccessibilityServices();
      state = state.copyWith(busy: false, lastA11y: outcome);
      ref.invalidate(launcherPrivilegeStatusProvider);
      return outcome;
    } catch (_) {
      state = state.copyWith(busy: false);
      rethrow;
    }
  }

  static const _emptyGrant = LauncherGrantOutcome(ok: false, results: []);
  static const _emptyDefault = LauncherDefaultHomeOutcome(ok: false);
  static const _emptyA11y = LauncherA11yEnableOutcome(ok: false);
}

/// Plain `NotifierProvider` (no autoDispose) because this Riverpod
/// version doesn't export `AutoDisposeNotifier`. The state itself is
/// tiny (a busy flag + the most recent outcome maps), so the
/// memory-retention cost of the session-scoped lifetime is
/// negligible. The companion `launcherPrivilegeStatusProvider` IS
/// `.autoDispose` (it caches a 9-row probe map) — that's where the
/// real churn would have been.
final launcherBootstrapControllerProvider =
    NotifierProvider<LauncherBootstrapController, LauncherBootstrapState>(
      LauncherBootstrapController.new,
    );
