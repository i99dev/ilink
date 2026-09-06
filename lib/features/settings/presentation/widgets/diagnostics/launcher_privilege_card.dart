/// Launcher-mode privilege grid + bootstrap actions.
///
/// Read state (what's currently granted) flows from
/// `launcherPrivilegeStatusProvider`. The action buttons go through
/// `launcherBootstrapControllerProvider`, which invalidates the status
/// provider after every successful action so the grid auto-refreshes
/// without the user having to press Refresh.
///
/// On BYD HUs there's a vendor-level home-app lock that no
/// `RoleManager.requestRoleIntent` or `cmd role add-role-holder` can
/// flip — when the user is in the stuck state (alias enabled but home
/// not the default) we surface an honest banner explaining the
/// limitation rather than silently looping the request.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../features/_car_domain/support/car_support_profile_provider.dart';
import '../../../../../features/_car_domain/support/hu_vendor.dart';
import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../../platform/launcher/launcher_bootstrap_controller.dart';
import '../../../../../platform/launcher/launcher_privilege_status.dart';
import '../../../../../kernel/ui/snackbar_x.dart';
import 'diagnostics_card.dart';

class LauncherPrivilegeCard extends ConsumerWidget {
  const LauncherPrivilegeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final asyncStatus = ref.watch(launcherPrivilegeStatusProvider);
    final bootstrap = ref.watch(launcherBootstrapControllerProvider);
    return DiagnosticsCard(
      title: 'Launcher-mode privileges',
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: () => ref.invalidate(launcherPrivilegeStatusProvider),
        visualDensity: VisualDensity.compact,
      ),
      child: asyncStatus.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) =>
            Text('Probe failed: $e', style: TextStyle(color: cs.error)),
        data: (s) =>
            _PrivilegeBody(status: s, bootstrap: bootstrap, ref: ref, cs: cs),
      ),
    );
  }
}

class _PrivilegeBody extends StatelessWidget {
  const _PrivilegeBody({
    required this.status,
    required this.bootstrap,
    required this.ref,
    required this.cs,
  });

  final LauncherPrivilegeStatus status;
  final LauncherBootstrapState bootstrap;
  final WidgetRef ref;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    // Map the per-grant outcome from the last Grant-all run back onto
    // the row keys so each row can show inline detail when its grant
    // attempt failed (rejected by HU, signature-only on this ROM, etc).
    // When grantAll has not been run yet, the map is empty and rows
    // render with no inline note.
    final lastResults = <String, LauncherGrantResult>{
      for (final r
          in (bootstrap.lastGrant?.results ?? const <LauncherGrantResult>[]))
        r.key: r,
    };
    final rows = <_PrivilegeRowSpec>[
      // 'Default home' is intentionally not shown as a grid row: on BYD it's
      // vendor-locked (see _BydLockBanner) and it stays reachable via the
      // "Make default home" button below. The visible count excludes it too.
      _PrivilegeRowSpec('Home alias enabled', status.homeAliasEnabled),
      _PrivilegeRowSpec('WRITE_SECURE_SETTINGS', status.writeSecureSettings),
      _PrivilegeRowSpec(
        'READ_LOGS',
        status.readLogs,
        outcome: lastResults['readLogs'],
      ),
      _PrivilegeRowSpec(
        'PACKAGE_USAGE_STATS',
        status.packageUsageStats,
        outcome: lastResults['packageUsageStats'],
      ),
      _PrivilegeRowSpec('SYSTEM_ALERT_WINDOW', status.systemAlertWindow),
      _PrivilegeRowSpec(
        'Battery unrestricted',
        status.ignoreBatteryOptimizations,
      ),
      _PrivilegeRowSpec(
        'A11y: remote control',
        status.remoteControlA11yEnabled,
      ),
      _PrivilegeRowSpec('A11y: watchdog', status.watchdogA11yEnabled),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final spec in rows) _PrivilegeRow(spec: spec),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Text(
            // Exclude the hidden 'Default home' item so the count matches
            // the rows actually shown above.
            '${status.grantedCount - (status.isDefaultHome ? 1 : 0)} of '
            '${LauncherPrivilegeStatus.totalCount - 1} granted',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ),
        _BootstrapActions(bootstrap: bootstrap, status: status, ref: ref),
        // BYD vendor lock — surface honest UX when the user is in the
        // stuck state (alias enabled, system rejecting the home flip).
        // Reads the support profile to scope the banner to BYD HUs;
        // Yuanfeng / Desay / aftermarket vendors don't have this lock.
        const _BydLockBanner(),
        if (bootstrap.lastGrant?.unreachableReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'ADB bridge unreachable: ${bootstrap.lastGrant!.unreachableReason}',
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ),
        if (bootstrap.lastDefaultHome?.aliasEnableFailureDetail != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Alias enable failed: ${bootstrap.lastDefaultHome!.aliasEnableFailureDetail}',
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ),
        // Recovery action for the two A11y rows. Only shown when
        // either service is currently disabled — keeps the UI clean
        // for users on a fully-bootstrapped HU.
        if (!status.remoteControlA11yEnabled || !status.watchdogA11yEnabled)
          _A11yRestampButton(bootstrap: bootstrap, ref: ref),
      ],
    );
  }
}

class _BydLockBanner extends ConsumerWidget {
  const _BydLockBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(carSupportProfileSnapshotProvider);
    final status = ref.watch(launcherPrivilegeStatusProvider).value;
    if (status == null) return const SizedBox.shrink();
    final isBydStuck =
        profile.huVendor == HuVendor.byd &&
        status.homeAliasEnabled &&
        !status.isDefaultHome;
    if (!isBydStuck) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final orange = Colors.orange.shade400;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: orange.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: orange.withAlpha(120)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_rounded, size: 16, color: orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    S.of(context).launcherBydLockedTitle,
                    style: TextStyle(
                      color: orange,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              S.of(context).launcherBydLockedBody,
              style: TextStyle(color: cs.onSurface, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _A11yRestampButton extends StatelessWidget {
  const _A11yRestampButton({required this.bootstrap, required this.ref});
  final LauncherBootstrapState bootstrap;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton.icon(
        onPressed: bootstrap.busy
            ? null
            : () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                final outcome = await ref
                    .read(launcherBootstrapControllerProvider.notifier)
                    .enableAccessibilityServices();
                if (!context.mounted) return;
                if (outcome.unreachableReason != null) {
                  messenger?.showText(
                    'ADB unreachable: ${outcome.unreachableReason}',
                  );
                  return;
                }
                final failed = outcome.results.where((r) => !r.ok).length;
                messenger?.showText(
                  outcome.ok
                      ? 'Accessibility services re-stamped'
                      : 'A11y enable partial: $failed cmd(s) failed',
                );
              },
        icon: const Icon(Icons.accessibility_new_rounded, size: 16),
        label: const Text('Enable accessibility services'),
      ),
    );
  }
}

/// Two-button action row: Grant-all on the left, Make-default-home on
/// the right. Both disable while any bootstrap call is in flight so the
/// user can't fire two overlapping shell sessions.
class _BootstrapActions extends StatelessWidget {
  const _BootstrapActions({
    required this.bootstrap,
    required this.status,
    required this.ref,
  });

  final LauncherBootstrapState bootstrap;
  final LauncherPrivilegeStatus status;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final busy = bootstrap.busy;
    final controller = ref.read(launcherBootstrapControllerProvider.notifier);
    final spinner = busy
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : null;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy ? null : () => _onGrantAll(context, controller),
            icon: spinner ?? const Icon(Icons.shield_outlined, size: 16),
            label: const Text('Grant all'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: busy ? null : () => _onDefaultHome(context, controller),
            icon:
                spinner ??
                Icon(
                  status.isDefaultHome
                      ? Icons.exit_to_app_rounded
                      : Icons.home_rounded,
                  size: 16,
                ),
            label: Text(
              status.isDefaultHome ? 'Disable launcher' : 'Make default home',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onGrantAll(
    BuildContext context,
    LauncherBootstrapController controller,
  ) async {
    // Capture messenger BEFORE awaiting — see _onDefaultHome for
    // the rationale (cold ADB resolves in 3-5s; the BuildContext
    // can be unmounted by then).
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await controller.grantAll();
    if (outcome.unreachableReason != null) {
      messenger?.showText('ADB unreachable: ${outcome.unreachableReason}');
      return;
    }
    final passed = outcome.results.where((r) => r.ok).length;
    final total = outcome.results.length;
    messenger?.showText('Grant: $passed of $total succeeded');
  }

  Future<void> _onDefaultHome(
    BuildContext context,
    LauncherBootstrapController controller,
  ) async {
    // Capture messenger BEFORE awaiting — the captured BuildContext
    // can be unmounted by the time the shell call returns (~3-5s on
    // cold ADB), and ScaffoldMessenger.maybeOf would then crash. The
    // messenger handle itself is async-safe.
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (status.isDefaultHome) {
      // Already default home — toggling off means disabling the alias
      // so the system home picker falls back to the OEM launcher
      // next time.
      await controller.setLauncherModeEnabled(false);
      messenger?.showText('Launcher mode disabled');
      return;
    }
    final outcome = await controller.requestDefaultHome();
    if (outcome.unreachableReason != null) {
      messenger?.showText('ADB unreachable: ${outcome.unreachableReason}');
    } else if (outcome.aliasEnableFailureDetail != null) {
      messenger?.showText(
        'Alias enable failed: ${outcome.aliasEnableFailureDetail}',
      );
    } else if (outcome.noPickerActivityDetail != null) {
      messenger?.showText(
        'No home-picker on this HU: ${outcome.noPickerActivityDetail}',
      );
    } else {
      messenger?.showText(
        outcome.ok
            ? 'Pick ilink in the home-app picker that just opened'
            : 'Failed to open home picker',
      );
    }
  }
}

class _PrivilegeRowSpec {
  const _PrivilegeRowSpec(this.label, this.granted, {this.outcome});
  final String label;
  final bool granted;
  final LauncherGrantResult? outcome;
}

class _PrivilegeRow extends StatelessWidget {
  const _PrivilegeRow({required this.spec});
  final _PrivilegeRowSpec spec;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final outcome = spec.outcome;
    final showError = outcome != null && !outcome.ok && !spec.granted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                spec.granted
                    ? Icons.check_circle_rounded
                    : Icons.cancel_outlined,
                size: 16,
                color: spec.granted ? Colors.green.shade400 : cs.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  spec.label,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          if (showError)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                outcome.output.isEmpty
                    ? 'Grant rejected by HU.'
                    : 'Grant rejected: ${outcome.output}',
                style: TextStyle(color: cs.error, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
