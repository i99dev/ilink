import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../../../features/_car_domain/command/command.dart';
import '../../../features/_car_domain/command/registry.dart';
import '../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../sdk/car/client.dart';
import '../../../features/_car_domain/consumer/car_consumer.dart';
import '../../../kernel/i18n/command_labels.dart';
import '../../../sdk/car/byd_features.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/settings/app_settings.dart';
import '../data/compat_probe.dart';
import '../data/compat_report.dart';
import '../data/compat_report_storage.dart';
import '../data/device_id_hasher.dart';
import 'sdk_actions_section.dart';

part 'compat_screen_models.dart';
part 'compat_screen_widgets.dart';

/// Local diagnostic probes and report export.
///   1) Probes — daemon / identity / live telemetry (re-read button)
///   2) Scan — compat probe + reachable/unknown/inactive table
///   3) Manual press — verdict grid (worked / didn't / unclear)
///   4) Fast actions — per-action int/bool fire bench with code= readback
///   5) AIDL binder probes — pre-built service.method transacts
///   6) Report — notes + Send button + pending count + last sent
///
/// One unified Send button packs probe verdicts AND bench runs AND
/// binder-probe results into a single CompatReport — testers don't
/// have to remember which surface produced which signal.
///
/// State lives in the widget because it's scoped to the screen's
/// lifetime; nothing here is worth caching across navigations.
class CompatScreen extends ConsumerStatefulWidget {
  const CompatScreen({super.key});

  @override
  ConsumerState<CompatScreen> createState() => _CompatScreenState();
}

class _CompatScreenState extends ConsumerState<CompatScreen> {
  // ── Compat probe + verdict grid state ─────────────────────────────
  List<ProbeResult>? _results;
  bool _scanning = false;
  double _scanProgress = 0;
  final Map<String, String> _verdicts = {};

  // ── Test-bench probe + outcomes state ─────────────────────────────
  /// Cached one-shot probes (daemon / identity / status). `null` until
  /// the first refresh lands.
  Map<String, dynamic>? _daemon;
  Map<String, dynamic>? _identity;
  Map<String, dynamic>? _status;

  /// Number of fast actions known to the daemon. Drives the bench
  /// banner. `null` before the first refresh; `0` is a real value
  /// (daemon up but encrypted table not loaded).
  int? _knownActionsCount;

  /// Single in-flight guard so mashing Run on multiple rows doesn't
  /// race the daemon and tangle logs.
  bool _busy = false;

  /// Pretty-printed last result per action_id (or `@service.method`
  /// for binder transacts). Each outcome carries the args used and
  /// the daemon's raw return so the report payload can replay the
  /// run on a different DiLink.
  final Map<String, _Outcome> _outcomes = {};

  // ── Report send state ─────────────────────────────────────────────
  final TextEditingController _notes = TextEditingController();
  bool _sending = false;
  DateTime? _lastSent;

  /// Reports stored locally from previous sessions.
  /// Refreshed on init and after every send so the badge stays
  /// accurate without subscribing to storage churn.
  int _pendingCount = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refreshProbes);
    Future.microtask(_refreshPendingCount);
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  // ── Probes (daemon / identity / status) ────────────────────────────

  Future<void> _refreshProbes() async {
    final client = ref.read(carClientProvider);
    final daemon = await _safeMap(client.daemonStatus);
    final identity = await _safeMap(client.identity);
    final status = await _safeMap(_readSdkStatus);
    final actions = await _safeList(client.knownActions);
    if (!mounted) return;
    setState(() {
      _daemon = daemon;
      _identity = identity;
      _status = status;
      _knownActionsCount = actions.length;
    });
  }

  Future<void> _refreshStatusOnly() async {
    final s = await _safeMap(_readSdkStatus);
    if (!mounted) return;
    setState(() => _status = s);
  }

  /// Snake_case status snapshot synthesised from the SDK's hot cache.
  /// Same shape the legacy `bridge.readStatus()` produced — label keys
  /// from `bydStatusLabelToCatalog`.
  Future<Map<String, dynamic>> _readSdkStatus() async {
    final client = ref.read(carClientProvider);
    final out = <String, dynamic>{};
    bydStatusLabelToCatalog.forEach((label, name) {
      final v = client.value(name);
      if (v != null) out[label] = v;
    });
    return out;
  }

  Future<void> _refreshPendingCount() async {
    final reports = await ref.read(compatReportStorageProvider).load();
    if (!mounted) return;
    setState(() => _pendingCount = reports.length);
  }

  // ── Compat probe scan ──────────────────────────────────────────────

  Future<void> _runScan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _results = null;
    });
    final probe = ref.read(compatProbeProvider);
    // CompatProbe runs all its lookups up-front, then classifies
    // locally per command — so we don't actually have per-command
    // progress. Fake-animate the bar while the probe runs so the UI
    // feels responsive.
    final ticker = _FakeProgressTicker();
    // ignore: unawaited_futures
    ticker.start((p) {
      if (!mounted || !_scanning) return;
      setState(() => _scanProgress = p);
    });
    final results = await probe.run();
    ticker.cancel();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _scanProgress = 1;
      _results = results;
    });
  }

  Future<void> _pressCommand(CarCommand cmd) async {
    if (cmd.requiresStationary) {
      final ok = await _confirmDanger(cmd);
      if (!ok) return;
    }
    try {
      await ref.read(carClientProvider).dispatch(cmd.id);
    } catch (_) {
      // Dispatch errors are surfaced via the verdict — user presses
      // "Didn't" if nothing happened.
    }
  }

  void _recordVerdict(CarCommand cmd, String verdict) {
    setState(() => _verdicts[cmd.id] = verdict);
  }

  // ── Test-bench fast actions + binder probes ───────────────────────

  Future<void> _runAction(
    String id, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _outcomes[id] = _Outcome.pending(args: args);
    });
    try {
      // Through the SDK so dev-bench taps trip the same integrity /
      // rate-limit / stationary stack as every other caller, and the
      // audit log records caller=dev_bench.
      final raw = await ref
          .read(carClientProvider)
          .dispatch(id, args: args, caller: DevBenchConsumer.instance);
      if (!mounted) return;
      setState(
        () => _outcomes[id] = _Outcome.fromBridge(
          raw.cast<String, dynamic>(),
          args: args,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _outcomes[id] = _Outcome.exception(e.toString(), args: args),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runTransact(
    String service,
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_busy) return;
    final id = '@$service.$method';
    final transactArgs = {'service': service, 'method': method, 'args': args};
    setState(() {
      _busy = true;
      _outcomes[id] = _Outcome.pending(args: transactArgs);
    });
    try {
      final raw = await ref
          .read(carClientProvider)
          .dispatch(
            'ac_transact',
            args: transactArgs,
            caller: DevBenchConsumer.instance,
          );
      if (!mounted) return;
      setState(
        () => _outcomes[id] = _Outcome.fromBridge(
          raw.cast<String, dynamic>(),
          args: transactArgs,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _outcomes[id] = _Outcome.exception(
          e.toString(),
          args: transactArgs,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Send report (unified) ──────────────────────────────────────────

  Future<void> _sendReport() async {
    if (_sending) return;
    final t = S.of(context);
    final settings = ref.read(settingsProvider).value ?? AppSettings.empty;
    if ((_results == null || _results!.isEmpty) &&
        _outcomes.values.every((o) => o.isPending)) {
      _snack(t.compatNothingToReport);
      return;
    }
    const shareVin = false;
    final report = await _buildReport(settings, shareVin: shareVin);
    final summary = await _confirmSend(report);
    if (!summary) return;

    setState(() => _sending = true);
    try {
      final saved = await ref.read(compatReportStorageProvider).enqueue(report);
      await Clipboard.setData(
        ClipboardData(
          text: const JsonEncoder.withIndent(
            '  ',
          ).convert(saved.toStorageJson()),
        ),
      );
      if (!mounted) return;
      setState(() {
        _lastSent = saved.reportedAt;
        _pendingCount += 1;
      });
      _snack('Report saved on this device and copied to clipboard.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<CompatReport> _buildReport(
    AppSettings settings, {
    required bool shareVin,
  }) async {
    final client = ref.read(carClientProvider);
    final probe = ref.read(compatProbeProvider);
    final packageInfo = await PackageInfo.fromPlatform();

    // Reuse cached probes when the user already refreshed; fall back
    // to fresh SDK calls so an offline tester still gets a valid
    // device map in the report.
    final daemonRaw = _daemon ?? await _safeMap(client.daemonStatus);
    final identityRaw = _identity ?? await _safeMap(client.identity);
    final statusRaw = _status ?? const <String, dynamic>{};

    // Commands list (probe + verdicts), unchanged from the
    // verdict-grid path so existing aggregator logic keeps working.
    final commands = <Map<String, dynamic>>[];
    for (final r in _results ?? const <ProbeResult>[]) {
      commands.add({...r.toJson(), 'user_verdict': ?_verdicts[r.registryId]});
    }

    // Bench outcomes, partitioned by id prefix. The map carries args,
    // ok, code, error, run_at — all the data the matrix aggregator
    // needs to correlate "what we sent" with "what the daemon
    // returned" without rerunning the test on a different DiLink.
    final benchRuns = <Map<String, dynamic>>[];
    final binderProbes = <Map<String, dynamic>>[];
    _outcomes.forEach((id, o) {
      if (o.isPending) return;
      final entry = <String, dynamic>{
        'id': id.startsWith('@') ? id.substring(1) : id,
        'args': o.args,
        'ok': o.ok,
        if (o.code != null) 'code': o.code,
        if (o.errorText != null) 'error': o.errorText,
        if (o.runAt != null) 'run_at': o.runAt!.toUtc().toIso8601String(),
      };
      if (id.startsWith('@')) {
        binderProbes.add(entry);
      } else {
        benchRuns.add(entry);
      }
    });

    // Snapshot the four telemetry fields the report cares about
    // straight from the SDK's hot cache — no more piggy-backing on
    // the typed CarGate sub-domains.
    final acState = client.value(BydFeatures.acPowerState);
    final speedKmh = client.value(BydFeatures.statisticSpeedSigVdis);
    final batteryPct = client.value(BydFeatures.statisticSocBatteryPercentage);
    final cabinTempC = client.value(BydFeatures.acTempInside);

    return CompatReport(
      schemaVersion: 1,
      reportedAt: DateTime.now().toUtc(),
      vinHash: shareVin ? DeviceIdHasher.hash(settings.deviceId) : null,
      device: {
        ...identityRaw,
        'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
      },
      daemon: {
        'adb': daemonRaw['adb'] == true,
        'daemon': daemonRaw['daemon'] == true,
        'mock': daemonRaw['mock'] == true,
        'known_actions_count':
            _knownActionsCount ?? probe.lastKnownActions.length,
      },
      sessionContext: {
        'ignition_on': acState == 1,
        'speed_kmh': speedKmh,
        'battery_pct': batteryPct,
        'cabin_temp_c': cabinTempC,
        // statusRaw is preserved as a fallback for fields the SDK
        // hot cache hasn't seen a push for yet.
        if (statusRaw.isNotEmpty) 'last_status_raw': statusRaw,
      },
      commands: commands,
      benchRuns: benchRuns,
      binderProbes: binderProbes,
      source: 'compat_unified',
      appNotes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
  }

  Future<Map<String, dynamic>> _safeMap(
    Future<Map<String, dynamic>> Function() fn,
  ) async {
    try {
      return await fn();
    } catch (_) {
      return const {};
    }
  }

  Future<List<String>> _safeList(Future<List<String>> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return const [];
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Dialogs ────────────────────────────────────────────────────────

  Future<bool> _confirmDanger(CarCommand cmd) async {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final displayLabel = localizedCommandLabel(t, cmd.id) ?? cmd.label;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainer,
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: AppColors.warning,
          size: 32,
        ),
        title: Text(t.compatConfirmDangerTitle(displayLabel)),
        content: Text(t.compatConfirmDangerBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.actionRun),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _confirmSend(CompatReport report) async {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surfaceContainer,
        title: const Text('Save diagnostic report'),
        content: SingleChildScrollView(
          child: DefaultTextStyle(
            style: TextStyle(
              color: cs.onSurface,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _kv(t.compatKvVinHash, report.vinHash ?? t.compatKvWithheld),
                _kv(
                  t.compatKvDevice,
                  report.device['android_build_model']?.toString() ??
                      t.valueUnknown,
                ),
                _kv(
                  t.compatKvDilink,
                  report.device['dilink_version_hint']?.toString() ?? '-',
                ),
                _kv(
                  t.compatKvDaemonOnline,
                  report.daemon['daemon'] == true ? t.valueYes : t.valueNo,
                ),
                _kv(
                  t.compatKvCommandsProbed,
                  report.commands.length.toString(),
                ),
                _kv(
                  t.compatKvVerdictsRecorded,
                  report.commands
                      .where((c) => c['user_verdict'] != null)
                      .length
                      .toString(),
                ),
                _kv(t.compatKvBenchRuns, report.benchRuns.length.toString()),
                _kv(
                  t.compatKvBinderProbes,
                  report.binderProbes.length.toString(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save and copy'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text('$k: $v'),
  );

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final registry = ref.watch(commandRegistryProvider);
    // Non-scrolling Column: the parent DevScreen owns the scroll view
    // so all dev sections (climate, windows, quick actions, compat)
    // share one scroll axis instead of nesting scrollables.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          title: t.compatCardProbes,
          subtitle: t.compatCardProbesSub,
          trailing: TextButton.icon(
            onPressed: _busy ? null : _refreshProbes,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.actionRefresh),
          ),
          child: _probesSection(),
        ),
        const SizedBox(height: 16),
        _Card(title: t.compatCardScan, child: _scanSection()),
        const SizedBox(height: 16),
        _Card(
          title: t.compatCardManualPress,
          subtitle: t.compatCardManualPressSub,
          child: _manualGrid(registry.values.toList()),
        ),
        const SizedBox(height: 16),
        const _Card(
          title: 'SDK confirm + freshness',
          subtitle:
              'Write-then-verify and per-name staleness — '
              'plain dispatch lives in Manual press / Fast actions',
          child: SdkActionsSection(),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.compatCardFastActions,
          subtitle: t.compatCardFastActionsSub,
          child: _fastActionsSection(),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.compatCardBinderProbes,
          subtitle: t.compatCardBinderProbesSub,
          child: _binderSection(),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.compatCardReport,
          trailing: _pendingCount > 0
              ? _PendingChip(count: _pendingCount)
              : null,
          child: _reportSection(),
        ),
      ],
    );
  }

  // ── Card content builders ─────────────────────────────────────────

  Widget _probesSection() {
    final t = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProbeBlock(title: t.compatProbeDaemonAdb, map: _daemon),
        const SizedBox(height: 8),
        _ProbeBlock(title: t.compatProbeCarIdentity, map: _identity),
        const SizedBox(height: 8),
        _ProbeBlock(
          title: t.compatProbeLiveTelemetry,
          map: _status,
          trailing: TextButton.icon(
            onPressed: _busy ? null : _refreshStatusOnly,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(t.compatProbeReread),
          ),
        ),
      ],
    );
  }

  Widget _scanSection() {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final results = _results;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _scanning ? _scanProgress : (results == null ? 0 : 1),
                backgroundColor: cs.outlineVariant,
                color: AppColors.accent,
                minHeight: 6,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _scanning ? null : _runScan,
              icon: const Icon(Icons.search),
              label: Text(_scanning ? t.compatScanning : t.compatScanButton),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (results != null) _resultsTable(results),
      ],
    );
  }

  Widget _resultsTable(List<ProbeResult> results) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final reachable = results.where((r) => r.outcome is ProbeReachable).length;
    final unknown = results
        .where((r) => r.outcome is ProbeUnknownToDaemon)
        .length;
    final inactive = results.where((r) => r.outcome is ProbeInactive).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _stat(t.compatStatReachable, reachable, AppColors.accent),
            const SizedBox(width: 12),
            _stat(t.compatStatUnknown, unknown, cs.onSurfaceVariant),
            const SizedBox(width: 12),
            _stat(t.compatStatInactive, inactive, AppColors.warning),
          ],
        ),
        const SizedBox(height: 12),
        for (final r in results) _resultRow(r),
      ],
    );
  }

  Widget _stat(String label, int value, Color color) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withAlpha(90)),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(ProbeResult r) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final outcome = r.outcome;
    final color = switch (outcome) {
      ProbeReachable() => AppColors.accent,
      ProbeUnknownToDaemon() => cs.onSurfaceVariant,
      ProbeInactive() => AppColors.warning,
      ProbeNotReady() => AppColors.warning,
      ProbeTimeout() => AppColors.warning,
      ProbeBridgeError() => AppColors.warning,
      ProbeDaemonOffline() => cs.onSurfaceVariant,
    };
    final status = (outcome.toJson()['status'] ?? 'unknown').toString();
    final displayLabel = localizedCommandLabel(t, r.registryId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayLabel ?? r.registryId,
                  style: TextStyle(color: cs.onSurface, fontSize: 12),
                ),
                Text(
                  r.registryId,
                  style: TextStyle(
                    color: cs.outline,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              status,
              style: TextStyle(
                color: color,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _manualGrid(List<CarCommand> commands) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final cmd in commands) _tile(cmd)],
    );
  }

  Widget _tile(CarCommand cmd) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final verdict = _verdicts[cmd.id];
    final tileColor = switch (verdict) {
      'worked' => AppColors.accent.withAlpha(30),
      'didnt' => AppColors.warning.withAlpha(30),
      'unclear' => cs.onSurfaceVariant.withAlpha(30),
      _ => cs.surfaceContainer,
    };
    final displayLabel = localizedCommandLabel(t, cmd.id) ?? cmd.label;
    return SizedBox(
      width: 180,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(cmd.icon, size: 18, color: cmd.color),
                const SizedBox(width: 6),
                if (cmd.requiresStationary)
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: AppColors.warning,
                  ),
                const Spacer(),
                IconButton(
                  tooltip: t.actionRun,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pressCommand(cmd),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                ),
              ],
            ),
            // Human-readable, localized label is the primary line; the raw
            // `cmd.id` (e.g. `hood.close`) sits underneath as a small mono
            // caption so testers can still cross-reference rows with the
            // canonical id that ships in the compat report JSON.
            Text(
              displayLabel,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              cmd.id,
              style: TextStyle(
                color: cs.outline,
                fontFamily: 'monospace',
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _verdictButton(cmd, 'worked', '✓', AppColors.accent),
                const SizedBox(width: 4),
                _verdictButton(cmd, 'didnt', '✗', AppColors.warning),
                const SizedBox(width: 4),
                _verdictButton(cmd, 'unclear', '?', cs.onSurfaceVariant),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _verdictButton(
    CarCommand cmd,
    String verdict,
    String label,
    Color color,
  ) {
    final cs = Theme.of(context).colorScheme;
    final active = _verdicts[cmd.id] == verdict;
    return Expanded(
      child: SizedBox(
        height: 28,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            side: BorderSide(color: active ? color : cs.outlineVariant),
            backgroundColor: active ? color.withAlpha(40) : Colors.transparent,
          ),
          onPressed: () => _recordVerdict(cmd, verdict),
          child: Text(label, style: TextStyle(color: color, fontSize: 14)),
        ),
      ),
    );
  }

  Widget _fastActionsSection() {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    if (_knownActionsCount != null) {
      final widgets = <Widget>[
        Text(
          t.compatBenchActionsLoaded(_knownActionsCount!),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
        ),
        const SizedBox(height: 8),
      ];
      _benchGroups.forEach((groupTitle, specs) {
        widgets.add(_GroupHeader(groupTitle));
        for (final spec in specs) {
          widgets.add(
            _ActionRow(
              spec: spec,
              outcome: _outcomes[spec.id],
              busy: _busy,
              onRun: (args) => _runAction(spec.id, args),
            ),
          );
        }
      });
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widgets,
      );
    }
    return Text(
      t.compatBenchPending,
      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
    );
  }

  Widget _binderSection() {
    final rows = <_BinderProbe>[
      const _BinderProbe(
        label: 'Fragrance — status (frag/status)',
        service: 'frag',
        method: 'status',
        args: {},
      ),
      const _BinderProbe(
        label: 'AC — services snapshot',
        service: 'services',
        method: 'snapshot',
        args: {},
      ),
      const _BinderProbe(
        label: 'AC — comfort_mode get (prop 131)',
        service: 'ac',
        method: 'get',
        args: {'id': 131, 'area': 256},
      ),
      const _BinderProbe(
        label: 'AC — rear_lock get (prop 135)',
        service: 'ac',
        method: 'get',
        args: {'id': 135, 'area': 256},
      ),
      const _BinderProbe(
        label: 'Seat — driver heat status (sid=1, type=1)',
        service: 'seat',
        method: 'status',
        args: {'sid': 1, 'type': 1},
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows
          .map(
            (probe) => _BinderRow(
              probe: probe,
              outcome: _outcomes['@${probe.service}.${probe.method}'],
              busy: _busy,
              onRun: () =>
                  _runTransact(probe.service, probe.method, probe.args),
            ),
          )
          .toList(),
    );
  }

  Widget _reportSection() {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final summary = _summarizeOutcomes();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.total > 0) ...[
          _BenchSummary(summary: summary),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _notes,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: t.compatNotesLabel,
            hintText: t.compatNotesHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _lastSent == null
                    ? 'No local report saved'
                    : 'Last saved: ${_lastSent!.toLocal()}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ),
            FilledButton.icon(
              onPressed: _sending ? null : _sendReport,
              icon: const Icon(Icons.save_alt),
              label: Text(_sending ? 'Saving?' : 'Save and copy report'),
            ),
          ],
        ),
      ],
    );
  }

  ({int ok, int fail, int err, int total}) _summarizeOutcomes() {
    var ok = 0;
    var fail = 0;
    var err = 0;
    for (final o in _outcomes.values) {
      if (o.isPending) continue;
      if (o.errorText != null) {
        err++;
      } else if (o.ok) {
        ok++;
      } else {
        fail++;
      }
    }
    return (ok: ok, fail: fail, err: err, total: ok + fail + err);
  }
}

// ────────────────────────────────────────────────────────────────────
// Fast-action group catalogue
// ────────────────────────────────────────────────────────────────────

/// Mirror of the encrypted runtime table — listed here so the bench
/// can render the input controls correctly even when knownActions()
/// hasn't loaded yet. Keep in sync with daemon's UnitDispatcher.
const Map<String, List<_ActionSpec>> _benchGroups = {
  'Doors / trunk / hood': [
    _ActionSpec.tap('door.lock'),
    _ActionSpec.tap('door.unlock'),
    _ActionSpec.tap('trunk.open'),
    _ActionSpec.tap('trunk.close'),
    _ActionSpec.tap('hood.open'),
    _ActionSpec.tap('hood.close'),
    _ActionSpec.tap('hood.stop'),
  ],
  'Windows (0=stop 1=open 2=close 3=full-down)': [
    _ActionSpec.intArg('window.fl'),
    _ActionSpec.intArg('window.rf'),
    _ActionSpec.intArg('window.rl'),
    _ActionSpec.intArg('window.rr'),
  ],
  'Climate': [
    _ActionSpec.boolArg('ac.power', argName: 'on'),
    _ActionSpec.intArg('ac.fan', hint: '0–7', defaultValue: 3),
    _ActionSpec.intArg('ac.temp', hint: '16–32 °C', defaultValue: 22),
    _ActionSpec.intArg('ac.mode', hint: '1=face 2=feet 3=both 4=defrost'),
    _ActionSpec.intArg('ac.cycle', hint: '0=fresh 1=recirc'),
    _ActionSpec.boolArg('ac.defrost_f', argName: 'on'),
    _ActionSpec.boolArg('ac.defrost_r', argName: 'on'),
    _ActionSpec.boolArg('ac.compressor', argName: 'on'),
    _ActionSpec.boolArg('ac.max_hot', argName: 'on'),
    _ActionSpec.boolArg('ac.max_cool', argName: 'on'),
  ],
  'Sunroof': [
    _ActionSpec.intArg('sunroof.ctl', hint: '0=stop 1=open 2=close 3=tilt'),
    _ActionSpec.intArg('sunroof.percent', hint: '0–100'),
  ],
  'Lights — exterior': [
    _ActionSpec.tap('light.head.on'),
    _ActionSpec.tap('light.head.off'),
    _ActionSpec.boolArg('light.fog_f', argName: 'on'),
    _ActionSpec.boolArg('light.fog_r', argName: 'on'),
    _ActionSpec.tap('light.turn_left', args: {'on': true}),
    _ActionSpec.tap('light.turn_right', args: {'on': true}),
    _ActionSpec.tap('light.flash'),
    _ActionSpec.tap('light.find_car'),
  ],
  'Lights — interior (atmos)': [
    _ActionSpec.tap('atmos.on'),
    _ActionSpec.tap('atmos.off'),
    _ActionSpec.intArg('atmos.bright', hint: '0–100', defaultValue: 80),
    _ActionSpec.intArg(
      'atmos.color',
      hint: 'packed 0xRRGGBB int',
      defaultValue: 0xFFFFFF,
    ),
  ],
  'Seats — heat (level 0–3)': [
    _ActionSpec.intArg('heat.drv.level'),
    _ActionSpec.intArg('heat.pass.level'),
    _ActionSpec.intArg('heat.rl.level'),
    _ActionSpec.intArg('heat.rr.level'),
  ],
  'Seats — vent (level 0–3)': [_ActionSpec.intArg('vent.drv.level')],
  'Seats — massage (driver/co-driver)': [
    _ActionSpec.intArg('massage.drv.mode'),
    _ActionSpec.intArg('massage.drv.level'),
    _ActionSpec.intArg('massage.co.mode'),
    _ActionSpec.intArg('massage.co.level'),
  ],
  'Fragrance': [
    _ActionSpec.intArg(
      'frag.on',
      argName: 'level',
      hint: '1–4',
      defaultValue: 2,
    ),
    _ActionSpec.tap('frag.off'),
    _ActionSpec.intArg(
      'frag.select',
      argName: 'slot',
      hint: '1–3',
      defaultValue: 1,
    ),
    _ActionSpec.tap('frag.status'),
  ],
};
