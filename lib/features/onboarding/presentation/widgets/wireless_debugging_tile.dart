import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/access/adb_bootstrap.dart';

/// Onboarding tile that surfaces the [AdbBootstrap] state. Three
/// visible variants:
///   * `applied` / `alreadyApplied` → minimal "✓ Background access"
///     confirmation row.
///   * `skipped` → "Enable Wireless debugging" instructions + Retry
///     button. Dominant case for first-time setup since cold launch
///     beats the user to it.
///   * `failed` → error pill with the first failing command, plus
///     Retry. Helps the technician triage on hardware that rejects
///     a specific grant.
///
/// English-only copy intentionally — sideloaded dev/installer build,
/// pre-translation. Localize when this hits a release that ships to
/// non-English-speaking technicians.
class WirelessDebuggingTile extends ConsumerStatefulWidget {
  const WirelessDebuggingTile({super.key});

  @override
  ConsumerState<WirelessDebuggingTile> createState() =>
      _WirelessDebuggingTileState();
}

class _WirelessDebuggingTileState extends ConsumerState<WirelessDebuggingTile> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(adbBootstrapChannelProvider).retry();
    } finally {
      // Repaint with whatever the retry produced. Even on exception
      // we want the tile back in a known state.
      if (mounted) {
        ref.invalidate(adbBootstrapStatusProvider);
        setState(() => _retrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final asyncStatus = ref.watch(adbBootstrapStatusProvider);

    return asyncStatus.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (status) {
        if (status.isApplied) {
          return _AppliedRow(
            label: 'Background access granted (v${status.persistedVersion}).',
            color: cs.primary,
          );
        }
        if (status.hasFailures) {
          return _ProblemCard(
            cs: cs,
            title: 'Background grant partially failed',
            body:
                'Some grants did not apply (${status.failureCount} failure${status.failureCount == 1 ? '' : 's'}). '
                'Most common cause: a permission requires the next OTA install. '
                'Detail: ${status.detail ?? 'unknown'}.',
            retrying: _retrying,
            onRetry: _retry,
          );
        }
        // Skipped or unknown — instruct enabling Wireless debugging.
        return _ProblemCard(
          cs: cs,
          title: 'Enable Wireless debugging to unlock background features',
          body:
              'Open Android Settings → System → Developer options → Wireless debugging, '
              'turn it on, then tap Retry below. This lets the app self-grant background '
              'permissions (Doze whitelist, continuous location, mic) over loopback ADB. '
              'Only required once per install.',
          retrying: _retrying,
          onRetry: _retry,
        );
      },
    );
  }
}

class _AppliedRow extends StatelessWidget {
  const _AppliedRow({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({
    required this.cs,
    required this.title,
    required this.body,
    required this.retrying,
    required this.onRetry,
  });

  final ColorScheme cs;
  final String title;
  final String body;
  final bool retrying;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.developer_mode, size: 20, color: cs.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonalIcon(
              onPressed: retrying ? null : onRetry,
              icon: retrying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 16),
              label: Text(retrying ? 'Retrying…' : 'Retry'),
            ),
          ),
        ],
      ),
    );
  }
}
